//
//  ImageBackgroundReplacer.swift
//  TeleDemo
//
//  Created by iapp on 16/10/25.
//


import UIKit
import AVFoundation
import AVKit
import Vision
import MetalPetal
import CoreImage

enum MetalPetalBackground {
    static let device = MTLCreateSystemDefaultDevice()!
    static let context = try! MTIContext(device: device)
    
    // MARK: - Replace background normally
    static func replaceBackgroundInImage(_ image: UIImage, with background: UIImage) throws -> UIImage? {
        return try replaceBackgroundInImage(image, with: background, applyBlur: false)
    }
    
    // MARK: - Replace background with optional blur
    static func replaceBackgroundInImage(_ image: UIImage, with background: UIImage, applyBlur: Bool = false) throws -> UIImage? {
        // 1️⃣ Resize background
        var bgResized = UIGraphicsImageRenderer(size: image.size).image { _ in
            background.draw(in: CGRect(origin: .zero, size: image.size))
        }
        
        // 2️⃣ Apply blur if requested
        if applyBlur {
            guard let ciImage = CIImage(image: bgResized) else { return nil }

            // Step 2a: Clamp edges to avoid white corners
            guard let clampFilter = CIFilter(name: "CIAffineClamp") else { return nil }
            clampFilter.setValue(ciImage, forKey: kCIInputImageKey)
            clampFilter.setValue(CGAffineTransform.identity, forKey: "inputTransform")
            guard let clamped = clampFilter.outputImage else { return nil }

            // Step 2b: Gaussian blur
            guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
            blurFilter.setValue(clamped, forKey: kCIInputImageKey)
            blurFilter.setValue(15, forKey: kCIInputRadiusKey)
            guard let blurred = blurFilter.outputImage else { return nil }

            // Step 2c: Crop back to original size
            let context = CIContext()
            if let cgImage = context.createCGImage(blurred.cropped(to: ciImage.extent), from: ciImage.extent) {
                bgResized = UIImage(cgImage: cgImage)
            }
        }
        
        // 3️⃣ Segmentation + compositing
        guard let cgImage = image.cgImage else { return nil }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let maskBuffer = request.results?.first?.pixelBuffer else { return nil }

        let ciMask = CIImage(cvPixelBuffer: maskBuffer)
        let context = CIContext()
        guard let maskCG = context.createCGImage(ciMask, from: ciMask.extent) else { return nil }

        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        guard let cgContext = UIGraphicsGetCurrentContext() else { return nil }

        // Flip context to match UIKit coordinates
        cgContext.translateBy(x: 0, y: image.size.height)
        cgContext.scaleBy(x: 1, y: -1)

        // Draw background first
        cgContext.draw(bgResized.cgImage!, in: CGRect(origin: .zero, size: image.size))

        // Clip person area using mask
        cgContext.clip(to: CGRect(origin: .zero, size: image.size), mask: maskCG)

        // Draw original image (person)
        cgContext.draw(cgImage, in: CGRect(origin: .zero, size: image.size))
        cgContext.resetClip()

        let finalImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return finalImage
    }
}
