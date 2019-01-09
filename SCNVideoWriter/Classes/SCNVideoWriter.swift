//
//  SCNVideoWriter.swift
//  Pods-SCNVideoWriter_Example
//
//  Created by Tomoya Hirano on 2017/07/31.
//

import UIKit
import SceneKit
import ARKit
import AVFoundation

public protocol ImageProcessor {
  func process(image: UIImage) -> UIImage
}

public class SCNVideoWriter {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
  private let renderer: SCNRenderer
  private let options: Options
  
  private let frameQueue = DispatchQueue(label: "com.noppelabs.SCNVideoWriter.frameQueue")
  private static let renderQueue = DispatchQueue(label: "com.noppelabs.SCNVideoWriter.renderQueue")
  private static let renderSemaphore = DispatchSemaphore(value: 3)
  private var initialTime: CFTimeInterval = 0.0
  
  public var updateFrameHandler: ((_ image: UIImage, _ time: CMTime) -> Void)? = nil
  public var imageProcessor: ImageProcessor?
  
  @available(iOS 11.0, *)
  public convenience init?(withARSCNView view: ARSCNView, options: Options = .default) throws {
    var options = options
    options.renderSize = CGSize(width: view.bounds.width * view.contentScaleFactor, height: view.bounds.height * view.contentScaleFactor)
    options.videoSize = options.renderSize
    try self.init(scene: view.scene, options: options)
  }
  
  public init?(scene: SCNScene, options: Options = .default) throws {
    self.options = options
    self.renderer = SCNRenderer(device: nil, options: nil)
    renderer.scene = scene
    
    self.writer = try AVAssetWriter(outputURL: options.outputUrl,
                                    fileType: AVFileType(rawValue: options.fileType))
    self.input = AVAssetWriterInput(mediaType: AVMediaType.video,
                                    outputSettings: options.assetWriterInputSettings)
    self.pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                                   sourcePixelBufferAttributes: options.sourcePixelBufferAttributes)
    prepare(with: options)
  }
  
  private func prepare(with options: Options) {
    if options.deleteFileIfExists {
      FileController.delete(file: options.outputUrl)
    }
    writer.add(input)
  }
  
  public func startWriting() {
    SCNVideoWriter.renderQueue.async { [weak self] in
      SCNVideoWriter.renderSemaphore.wait()
      self?.startInputPipeline()
    }
  }
  
  public func finishWriting(completionHandler: (@escaping (_ url: URL) -> Void)) {
    let outputUrl = options.outputUrl
    input.markAsFinished()
    writer.finishWriting {
      completionHandler(outputUrl)
      SCNVideoWriter.renderSemaphore.signal()
    }
  }
  
  public func sceneDidUpdate(atTime time: TimeInterval) {
    frameQueue.async { [weak self] in
        guard let `self` = self,
            let pool = self.pixelBufferAdaptor.pixelBufferPool,
            self.input.isReadyForMoreMediaData else {
                return
        }
        self.renderSnapshot(atTime: time,
                            pool: pool,
                            renderSize: self.options.renderSize,
                            videoSize: self.options.videoSize)
    }
  }
  
  private func startInputPipeline() {
    initialTime = CFAbsoluteTimeGetCurrent()
    writer.startWriting()
    writer.startSession(atSourceTime: CMTime.zero)
    input.requestMediaDataWhenReady(on: frameQueue, using: {})
  }
  
  private func renderSnapshot(atTime time: TimeInterval, pool: CVPixelBufferPool, renderSize: CGSize, videoSize: CGSize) {
    guard writer.status == .writing else {
      return
    }
    autoreleasepool {
      let now = CFAbsoluteTimeGetCurrent()
      let currentTime = now - initialTime
      let snapshot = renderer.snapshot(atTime: time, with: renderSize, antialiasingMode: .multisampling4X)
      let image = imageProcessor?.process(image: snapshot) ?? snapshot
      guard let croppedImage = image.fill(at: videoSize) else { return }
      guard let pixelBuffer = PixelBufferFactory.make(with: videoSize, from: croppedImage, usingBuffer: pool) else { return }
      let value: Int64 = Int64(currentTime * CFTimeInterval(options.timeScale))
      let presentationTime = CMTimeMake(value: value, timescale: options.timeScale)
      pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
      updateFrameHandler?(croppedImage, presentationTime)
    }
  }
}


