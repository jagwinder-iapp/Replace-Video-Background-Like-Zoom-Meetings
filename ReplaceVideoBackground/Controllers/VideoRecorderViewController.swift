//
//  VideoRecorderViewController.swift
//  TeleDemo
//
//  Created by iapp on 16/10/25.
//


import UIKit
import AVFoundation
import PhotosUI
import SVProgressHUD

class VideoRecorderViewController: UIViewController {
    
    //MARK: - IBOutlets
    @IBOutlet weak var playerBackgroundView: UIView!
    @IBOutlet weak var timerLabel: UILabel!

    //MARK: - Properties
    private var captureSession: AVCaptureSession!
    private var videoOutput: AVCaptureMovieFileOutput!
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var selectedVideoURL: URL?

    //MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
        setupTimerLabel()
    }

    // MARK: - Camera Setup
    private func setupCamera() {
        captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            print("❌ Front camera not available.")
            return
        }

        if captureSession.canAddInput(input) { captureSession.addInput(input) }

        videoOutput = AVCaptureMovieFileOutput()
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }

        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.frame = playerBackgroundView.bounds
        previewLayer.videoGravity = .resizeAspectFill
        playerBackgroundView.layer.addSublayer(previewLayer)

        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
        }
    }

    //MARK: - Set Timer label
    private func setupTimerLabel() {
        timerLabel.clipsToBounds = true
        timerLabel.layer.cornerRadius = 5
    }
    
    //MARK: - Switch camera (Front + Back)
    func switchCamera(to position: AVCaptureDevice.Position) {
        guard let session = captureSession else { return }
        guard let newCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            print("\(position == .front ? "Front" : "Back") camera not available.")
            return
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: newCamera)
            session.beginConfiguration()
            
            // Remove old video inputs
            for oldInput in session.inputs {
                if let deviceInput = oldInput as? AVCaptureDeviceInput,
                   deviceInput.device.hasMediaType(.video) {
                    session.removeInput(deviceInput)
                }
            }
            
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            // Fix preview mirroring
            if let previewConnection = previewLayer.connection, previewConnection.isVideoMirroringSupported {
                previewConnection.automaticallyAdjustsVideoMirroring = false
                previewConnection.isVideoMirrored = (position == .front)
            }
            
            // Fix video output mirroring
            if let videoOutput = videoOutput,
               let outputConnection = videoOutput.connection(with: .video),
               outputConnection.isVideoMirroringSupported {
                outputConnection.automaticallyAdjustsVideoMirroring = false
                // Mirror only front camera if you want recording flipped like selfie
                outputConnection.isVideoMirrored = false
            }
            
            session.commitConfiguration()
            print("✅ Switched to \(position == .front ? "front" : "back") camera")
            
        } catch {
            print("Error switching camera:", error)
        }
    }


    // MARK: - Recording Controls
    @IBAction func startRecording() {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("recorded.mov")
        try? FileManager.default.removeItem(at: outputURL)

        selectedVideoURL = nil

        if let connection = videoOutput.connection(with: .video),
           connection.isVideoMirroringSupported {

            // Mirror only if front camera
            if let input = captureSession?.inputs.first(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) ?? false }) as? AVCaptureDeviceInput {
                if input.device.position == .front {
                    connection.isVideoMirrored = true
                } else {
                    connection.isVideoMirrored = false
                }
            }

            connection.automaticallyAdjustsVideoMirroring = false
        }

        videoOutput.startRecording(to: outputURL, recordingDelegate: self)
        startTimer()
        print("🎬 Recording started...")
    }


    //MARK: - Stop Recording
    @IBAction func stopRecording() {
        print("🛑 Stop button tapped.")
        
        if videoOutput.isRecording {
            videoOutput.stopRecording()
            stopTimer()
        } else {
            print("⚠️ No recording in progress.")
        }
    }
    
    // MARK: - Switch to Front Camera
    @IBAction func frontCameraAction(_ sender: Any) {
        switchCamera(to: .front)
    }


    // MARK: - Switch to Back Camera
    @IBAction func backCameraAction(_ sender: Any) {
        switchCamera(to: .back)
    }


    // MARK: - Open Gallery (Auto-preview)
    @IBAction func openGalleryButtonAction(_ sender: Any) {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.center = view.center
        indicator.color = .white
        indicator.startAnimating()
        view.addSubview(indicator)
        view.isUserInteractionEnabled = false
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let picker = UIImagePickerController()
            picker.delegate = self
            picker.sourceType = .photoLibrary
            picker.mediaTypes = ["public.movie"]
            
            // Present picker
            self.present(picker, animated: true) {
                // Once picker appears, remove loader
                indicator.stopAnimating()
                indicator.removeFromSuperview()
                self.view.isUserInteractionEnabled = true
            }
        }
    }

    // MARK: - Start Timer
    private func startTimer() {
        recordingStartTime = Date()
        timerLabel.isHidden = false
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateTimer()
        }
    }

    // MARK: - Stop Timer
    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        timerLabel.isHidden = true
    }

    // MARK: - Update Timer
    private func updateTimer() {
        guard let startTime = recordingStartTime else { return }
        let elapsed = Int(Date().timeIntervalSince(startTime))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        timerLabel.text = String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Preview Navigation
    private func openPreview(with url: URL) {
        DispatchQueue.main.async {
            let storyboard = UIStoryboard(name: "Main", bundle: nil)
            guard let previewVC = storyboard.instantiateViewController(withIdentifier: "VideoPreviewViewController") as? VideoPreviewViewController else { return }
            previewVC.videoURL = url
            previewVC.modalPresentationStyle = .fullScreen
            self.present(previewVC, animated: true)
        }
    }
}

// MARK: - Recording Delegate
extension VideoRecorderViewController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        print("✅ Recording finished at: \(outputFileURL)")
        selectedVideoURL = outputFileURL
        // Go to preview automatically when recording stops
        openPreview(with: outputFileURL)
    }
}

// MARK: - Gallery Delegate
extension VideoRecorderViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true)
        guard let videoURL = info[.mediaURL] as? URL else { return }
        print("🎞 Selected video: \(videoURL)")
        selectedVideoURL = videoURL
        
        // Immediately open preview
        openPreview(with: videoURL)
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}
