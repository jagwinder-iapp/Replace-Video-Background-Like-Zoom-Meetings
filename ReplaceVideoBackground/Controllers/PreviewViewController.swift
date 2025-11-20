//
//  PreviewViewController.swift
//  TeleDemo
//
//  Created by iapp on 25/10/25.
//


import UIKit
import CoreML

class PreviewViewController: UIViewController {
    
    @IBOutlet weak var imageView: UIImageView!
    
    var image: UIImage?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        imageView.image = image
    }
    


    
    @IBAction func backbuttonclicked(_ sender: Any) {
        self.dismiss(animated: true)
    }
}
