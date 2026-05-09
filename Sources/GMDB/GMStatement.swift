//
//  GMStatement.swift
//  GMDB
//
//  Based on FMDB by August Mueller
//  Ported to Swift by Casey Fleser on 8/13/25.
//

import Foundation
import SQLite3

public class GMStatement: NSObject {
    private(set) var statement: OpaquePointer? = nil
    public internal(set) var query: String = ""
    public internal(set) var useCount: Int = 0
    public internal(set) var inUse: Bool = false

    public override var description: String { "\(useCount) hit(s) for query \(query)" }

    public init(statement: OpaquePointer? = nil) {
        self.statement = statement
    }
    
    deinit {
        close()
    }

    public func close() {
        if let statement {
            sqlite3_finalize(statement)
        }

        statement = nil
        inUse = false
    }

    public func reset() {
        if let statement {
            sqlite3_reset(statement)
        }

        inUse = false
    }
}
