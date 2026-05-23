//
//  iClaw-Bridging-Header.h
//
//  Exposes Objective-C helpers to Swift. Currently wires in
//  ObjCExceptionCatcher so Swift can catch NSExceptions raised by ObjC
//  frameworks (CoreData / SwiftData) that Swift's own `try?` cannot catch.
//

#import "Services/ObjCExceptionCatcher.h"
