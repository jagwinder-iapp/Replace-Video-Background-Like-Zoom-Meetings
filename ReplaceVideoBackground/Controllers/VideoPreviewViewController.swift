//
//  VideoPreviewViewController.swift
//  TeleDemo
//
//  Created by iapp on 16/10/25.
//

import UIKit
import AVFoundation
import Vision
import AVKit


class VideoPreviewViewController: UIViewController {
    
    //MARK: - IBOutlets
    @IBOutlet weak var previewImageView: UIImageView!
    @IBOutlet weak var changeBackgroundButton: UIButton!
    @IBOutlet weak var nextButton: UIButton!
    
    //MARK: - Properties
    var videoURL: URL!
    private var originalFrameImage: UIImage?
    var selectedBackgroundImage: UIImage?
    private var activityIndicator: UIActivityIndicatorView?
    var isBlurApplied = false
    private var processedVideosCache: [String: URL] = [:]

    
    //MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        extractFirstFrame()
        setupUI()
    }
    
    //MARK: - Setup UI
    private func setupUI() {
        previewImageView.contentMode = .scaleAspectFill
        changeBackgroundButton.layer.cornerRadius = 8
        nextButton.layer.cornerRadius = 8
    }
    
    //MARK: - Extract first frame of video
    private func extractFirstFrame() {
        let asset = AVAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        
        if let cgImage = try? imageGenerator.copyCGImage(at: .zero, actualTime: nil) {
            let frameImage = UIImage(cgImage: cgImage)
            previewImageView.image = frameImage
            originalFrameImage = frameImage
        }
    }
    
    private func cacheKey(for background: UIImage, blur: Bool) -> String {
        let data = background.pngData() ?? Data()
        let hash = data.hashValue
        return "\(hash)_blur_\(blur)"
    }

    
    // MARK: - Global Indicator Methods
    private func showLoadingIndicator() {
        if activityIndicator == nil {
            let indicator = UIActivityIndicatorView(style: .large)
            indicator.center = view.center
            indicator.color = .white
            indicator.hidesWhenStopped = true
            view.addSubview(indicator)
            activityIndicator = indicator
        }
        
        activityIndicator?.startAnimating()
        view.isUserInteractionEnabled = false
    }
    
    private func hideLoadingIndicator() {
        activityIndicator?.stopAnimating()
        view.isUserInteractionEnabled = true
    }
    
    //MARK: - Dismiss action
    @IBAction func backButtonAction(_ sender: UIButton) {
        self.dismiss(animated: true)
    }
    
    //MARK: - Open Gallery to change background image
    @IBAction func changeBackgroundTapped() {
        showLoadingIndicator()
        isBlurApplied = false
        let picker = UIImagePickerController()
        picker.delegate = self
        picker.sourceType = .photoLibrary
        picker.allowsEditing = false
        // Present picker
        self.present(picker, animated: true) { [weak self] in
            self?.hideLoadingIndicator()
        }
        
    }
    
    @IBAction func removeBackgroundAction(_ sender: Any) {
        guard let frameImage = originalFrameImage else { return }
        
        // Reset selected background and blur state
        selectedBackgroundImage = nil
        isBlurApplied = false
        
        showLoadingIndicator()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Replace background with original frame itself (no blur, original video background)
                let output = try MetalPetalBackground.replaceBackgroundInImage(frameImage, with: frameImage, applyBlur: false)
                DispatchQueue.main.async {
                    self.previewImageView.image = output
                    self.hideLoadingIndicator()
                }
            } catch {
                DispatchQueue.main.async {
                    print("Failed to remove background:", error)
                    self.hideLoadingIndicator()
                }
            }
        }
    }

    
    @IBAction func applyBlurAction(_ sender: Any) {
        guard let frameImage = originalFrameImage else { return }
         
         // When blur is applied, clear any selected background
         selectedBackgroundImage = nil
         isBlurApplied = true
         
         showLoadingIndicator()
         DispatchQueue.global(qos: .userInitiated).async {
             do {
                 // Apply blur to the original image background only
                 let output = try MetalPetalBackground.replaceBackgroundInImage(frameImage, with: frameImage, applyBlur: true)
                 DispatchQueue.main.async {
                     self.previewImageView.image = output
                     self.hideLoadingIndicator()
                 }
             } catch {
                 DispatchQueue.main.async {
                     print("Failed to apply blur:", error)
                     self.hideLoadingIndicator()
                 }
             }
         }
        
        
        
        //Blur selected image
//        guard let frameImage = originalFrameImage else { return }
//        isBlurApplied = true
//        // Use existing selected background, or fallback to the original frame image itself
//        let bgImage: UIImage
//        if let selectedBG = selectedBackgroundImage {
//            bgImage = selectedBG
//        } else {
//            bgImage = frameImage
//            selectedBackgroundImage = bgImage // save it so next taps know
//        }
//
//        showLoadingIndicator()
//        DispatchQueue.global(qos: .userInitiated).async {
//            do {
//                let output = try MetalPetalBackground.replaceBackgroundInImage(frameImage, with: bgImage, applyBlur: true)
//                DispatchQueue.main.async {
//                    self.previewImageView.image = output
//                    self.hideLoadingIndicator()
//                }
//            } catch {
//                DispatchQueue.main.async {
//                    print("Failed to apply blur:", error)
//                    self.hideLoadingIndicator()
//                }
//            }
//        }
    }

    @IBAction func removeBlurAction(_ sender: Any) {
        guard let frameImage = originalFrameImage else { return }
        isBlurApplied = false
        
        // Use existing selected background or fallback to original frame
        let bgImage: UIImage = selectedBackgroundImage ?? frameImage
        
        showLoadingIndicator()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try MetalPetalBackground.replaceBackgroundInImage(frameImage, with: bgImage, applyBlur: false)
                DispatchQueue.main.async {
                    self.previewImageView.image = output
                    self.hideLoadingIndicator()
                }
            } catch {
                DispatchQueue.main.async {
                    print("Failed to remove blur:", error)
                    self.hideLoadingIndicator()
                }
            }
        }
    }
    
    //MARK: - Tap Next to play video with replaced background
    @IBAction func nextTapped() {
        guard let backgroundImage = selectedBackgroundImage ?? originalFrameImage else { return }
        showLoadingIndicator()
        
        let key = cacheKey(for: backgroundImage, blur: isBlurApplied)
        
        // If already processed, use cached video
        if let cachedURL = processedVideosCache[key] {
            hideLoadingIndicator()
            playVideo(url: cachedURL)
            return
        }
        
        // Otherwise, process video
        BackgroundReplacerMetal.shared.replaceBackground(in: videoURL, with: backgroundImage, applyBlur: isBlurApplied) { [weak self] outputURL in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.hideLoadingIndicator()
                self.processedVideosCache[key] = outputURL // cache it
                self.playVideo(url: outputURL)
            }
        }
    }

    
    private func playVideo(url: URL) {
        let playerVC = AVPlayerViewController()
        playerVC.player = AVPlayer(url: url)
        self.present(playerVC, animated: true) {
            playerVC.player?.play()
        }
    }

}

//MARK: - Gallery picker delegate
extension VideoPreviewViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true)
        
        guard let frameImage = self.originalFrameImage,
              let selectedBackground = info[.originalImage] as? UIImage else {
            return
        }
        
        // Save selected image for next tap
        self.selectedBackgroundImage = selectedBackground
        
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.center = self.previewImageView.center
        indicator.startAnimating()
        self.view.addSubview(indicator)
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try MetalPetalBackground.replaceBackgroundInImage(frameImage, with: selectedBackground)
                DispatchQueue.main.async {
                    self.previewImageView.image = output
                    indicator.stopAnimating()
                    indicator.removeFromSuperview()
                }
            } catch {
                DispatchQueue.main.async {
                    print("Failed to replace background:", error)
                    indicator.stopAnimating()
                    indicator.removeFromSuperview()
                }
            }
        }
    }
    
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}


