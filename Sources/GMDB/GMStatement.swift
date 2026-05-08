//
//  GMStatement.swift
//  GMDB
//
//  Based on FMDB by August Mueller
//  Ported to Swift by Casey Fleser on 8/13/25.
//

import Foundation
import SQLite3

class GMStatement: NSObject {
    var statement: OpaquePointer? = nil
    var query: String = ""
    var useCount: Int = 0
    var inUse: Bool = false

    override var description: String { "\(useCount) hit(s) for query \(query)" }

    init(statement: OpaquePointer? = nil) {
        self.statement = statement
    }
    
    deinit {
        close()
    }

    func close() {
        if let statement {
            sqlite3_finalize(statement)
        }

        statement = nil
        inUse = false
    }

    func reset() {
        if let statement {
            sqlite3_reset(statement)
        }

        inUse = false
    }
}
