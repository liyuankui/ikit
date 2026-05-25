#!/usr/bin/env swift
import Vision
import Foundation

// 从命令行参数获取图片路径
let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("Usage: swift ocr_images.swift <image_path>")
    exit(1)
}

let imagePath = arguments[1]
let imageUrl = URL(fileURLWithPath: imagePath)

// 检查文件存在
guard FileManager.default.fileExists(atPath: imagePath) else {
    print("Error: File not found - \(imagePath)")
    exit(1)
}

// 加载图片
guard let imageData = try? Data(contentsOf: imageUrl),
      let image = UIImage(data: imageData) else {
    print("Error: Failed to load image")
    exit(1)
}

// 创建 OCR 请求
let request = VNRecognizeTextRequest()
request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
request.usesLanguageCorrection = true
request.recognitionLevel = .accurate

// 创建 handler
let handler = VNImageRequestHandler(cgImage: image.cgImage!, options: [:])

// 执行 OCR
do {
    try handler.perform([request])

    guard let results = request.results, !results.isEmpty else {
        print("No text found")
        exit(0)
    }

    // 提取所有文本
    var extractedText = ""
    for result in results {
        if let observation = result as? VNRecognizedTextObservation,
           let topCandidate = observation.topCandidates(1).first {
            extractedText += topCandidate.string + "\n"
        }
    }

    print(extractedText, terminator: "")

} catch {
    print("Error: \(error)")
    exit(1)
}

// UIImage extension for Swift
#if canImport(UIKit)
import UIKit
typealias UIImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias UIImage = NSImage
extension UIImage {
    var cgImage: CGImageRef? {
        return self.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
#endif
