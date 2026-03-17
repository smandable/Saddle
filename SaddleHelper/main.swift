//
//  main.swift
//  SaddleHelper
//
//  Created by Sean Mandable on 3/16/26.
//

import Foundation
import os.log

let mainLogger = Logger(subsystem: "com.saddle.helper", category: "Main")

mainLogger.info("SaddleHelper daemon starting")

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: "com.saddle.helper")
listener.delegate = delegate
listener.resume()

mainLogger.info("SaddleHelper listening for XPC connections")

dispatchMain()
