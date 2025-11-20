//
//  BackgroundReplacerMetal.swift
//  TeleDemo
//
//  Created by iapp on 24/10/25.
//

import UIKit
import AVFoundation
import Vision
import MetalPetal

class BackgroundReplacerMetal {
    
    static let shared = BackgroundReplacerMetal()
    private init() {}
    
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var mtiContext: MTIContext = try! MTIContext(device: device)
    
    // Reuse Vision request for all frames
    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .balanced
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return req
    }()
    
    // MARK: - Public API: Replace background for video
    func replaceBackground(in videoURL: URL, with backgroundImage: UIImage, applyBlur: Bool = false, completion: @escaping (URL) -> Void) {
        
        let asset = AVAsset(url: videoURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            print("No video track found.")
            return
        }
        
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("replaced_bg.mov")
        try? FileManager.default.removeItem(at: tempURL)
        
        // --- Fix video orientation using AVMutableComposition ---
        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        
        do {
            try compVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration),
                                               of: videoTrack,
                                               at: .zero)
        } catch {
            print("Failed to insert video track:", error)
            return
        }
        
        // Copy audio if available
        if let audioTrack = asset.tracks(withMediaType: .audio).first,
           let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration),
                                                of: audioTrack,
                                                at: .zero)
        }
        
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(videoTrack.nominalFrameRate == 0 ? 30 : Int(videoTrack.nominalFrameRate)))
        let naturalSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        videoComposition.renderSize = CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
        layerInstruction.setTransform(videoTrack.preferredTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        
        // Export oriented video to temp
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            print("Failed to create export session")
            return
        }
        exportSession.outputURL = tempURL
        exportSession.outputFileType = .mov
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true
        
        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                self.replaceBackgroundWithMetalPetal(videoURL: tempURL, backgroundImage: backgroundImage, applyBlur: applyBlur, completion: completion)
            case .failed, .cancelled:
                print("Export failed:", exportSession.error ?? "unknown error")
            default: break
            }
        }
    }
    
    // MARK: - MetalPetal background replacement
    func replaceBackgroundWithMetalPetal(videoURL: URL, backgroundImage: UIImage, applyBlur: Bool = false, completion: @escaping (URL) -> Void) {
        
        let asset = AVAsset(url: videoURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return }
        
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("replaced_bg_final.mov")
        try? FileManager.default.removeItem(at: outputURL)
        
        // Reader
        let reader: AVAssetReader
        let videoReaderOutput: AVAssetReaderTrackOutput
        var audioReaderOutput: AVAssetReaderTrackOutput?
        
        do {
            reader = try AVAssetReader(asset: asset)
            
            videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ])
            reader.add(videoReaderOutput)
            
            if let audioTrack = asset.tracks(withMediaType: .audio).first {
                let aOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                if reader.canAdd(aOut) {
                    reader.add(aOut)
                    audioReaderOutput = aOut
                }
            }
        } catch {
            print("Reader setup failed:", error)
            return
        }
        
        // Writer
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else {
            print("Writer creation failed")
            return
        }
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoTrack.naturalSize.width,
            AVVideoHeightKey: videoTrack.naturalSize.height
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: videoTrack.naturalSize.width,
            kCVPixelBufferHeightKey as String: videoTrack.naturalSize.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(videoInput)
        
        var audioInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            aInput.expectsMediaDataInRealTime = false
            writer.add(aInput)
            audioInput = aInput
        }
        
        writer.startWriting()
        reader.startReading()
        writer.startSession(atSourceTime: .zero)
        
        // --- Prepare background image for frames ---
        var bgUIImage = backgroundImage
        if applyBlur {
            if let ciImage = CIImage(image: backgroundImage),
               let clampFilter = CIFilter(name: "CIAffineClamp"),
               let blurFilter = CIFilter(name: "CIGaussianBlur") {
                
                clampFilter.setValue(ciImage, forKey: kCIInputImageKey)
                clampFilter.setValue(CGAffineTransform.identity, forKey: "inputTransform")
                
                guard let clamped = clampFilter.outputImage else { return }
                
                blurFilter.setValue(clamped, forKey: kCIInputImageKey)
                blurFilter.setValue(12, forKey: kCIInputRadiusKey)
                
                if let blurred = blurFilter.outputImage {
                    let context = CIContext()
                    if let cgImage = context.createCGImage(blurred.cropped(to: ciImage.extent), from: ciImage.extent) {
                        bgUIImage = UIImage(cgImage: cgImage)
                    }
                }
            }
        }
        let bgImage = MTIImage(cgImage: bgUIImage.cgImage!, options: [.SRGB: false], isOpaque: true)
        
        // Dispatch group for video + audio
        let group = DispatchGroup()
        
        // ---------- Video processing ----------
        group.enter()
        let processingQueue = DispatchQueue(label: "video.process.queue")
        videoInput.requestMediaDataWhenReady(on: processingQueue) {
            while videoInput.isReadyForMoreMediaData {
                autoreleasepool {
                    if reader.status == .completed || reader.status == .failed || reader.status == .cancelled {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    
                    guard let sampleBuffer = videoReaderOutput.copyNextSampleBuffer(),
                          let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    
                    var frameCI = CIImage(cvPixelBuffer: pixelBuffer)
                    if videoTrack.preferredTransform != .identity {
                        frameCI = frameCI.transformed(by: videoTrack.preferredTransform)
                    }
                    
                    // Vision segmentation
                    let handler = VNImageRequestHandler(ciImage: frameCI, options: [:])
                    try? handler.perform([self.segmentationRequest])
                    
                    guard let maskBuffer = self.segmentationRequest.results?.first?.pixelBuffer else {
                        // fallback: write original frame
                        var fallbackBuffer: CVPixelBuffer?
                        if CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &fallbackBuffer) == kCVReturnSuccess,
                           let fb = fallbackBuffer {
                            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                            CVPixelBufferLockBaseAddress(fb, [])
                            memcpy(CVPixelBufferGetBaseAddress(fb), CVPixelBufferGetBaseAddress(pixelBuffer), CVPixelBufferGetDataSize(pixelBuffer))
                            CVPixelBufferUnlockBaseAddress(fb, [])
                            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                            adaptor.append(fb, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                        }
                        return
                    }
                    
                    // MetalPetal blend
                    let maskImage = MTIImage(cvPixelBuffer: maskBuffer, alphaType: .alphaIsOne)
                    let personImage = MTIImage(cvPixelBuffer: pixelBuffer, alphaType: .alphaIsOne)
                    let blendFilter = MTIBlendWithMaskFilter()
                    blendFilter.inputImage = personImage
                    blendFilter.inputBackgroundImage = bgImage
                    blendFilter.inputMask = MTIMask(content: maskImage, component: .red, mode: .normal)
                    
                    guard let outputImage = blendFilter.outputImage else { return }
                    
                    var renderedBuffer: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &renderedBuffer) == kCVReturnSuccess,
                          let finalBuffer = renderedBuffer else { return }
                    
                    try? self.mtiContext.render(outputImage, to: finalBuffer)
                    adaptor.append(finalBuffer, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                }
            }
        }
        
        // ---------- Audio processing ----------
        if let audioReaderOutput = audioReaderOutput, let audioInput = audioInput {
            group.enter()
            let audioQueue = DispatchQueue(label: "audio.copy.queue")
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    if let buffer = audioReaderOutput.copyNextSampleBuffer() {
                        audioInput.append(buffer)
                    } else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        
        // Finish writing
        group.notify(queue: DispatchQueue.global()) {
            if reader.status == .reading {
                reader.cancelReading()
            }
            writer.finishWriting {
                DispatchQueue.main.async {
                    completion(outputURL)
                }
            }
        }
    }
}
