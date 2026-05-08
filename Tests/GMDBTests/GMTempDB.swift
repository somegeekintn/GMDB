//
//  GMTempDB.swift
//  GMDB
//
//  Based on FMDB by August Mueller
//  Ported to Swift by Casey Fleser on 8/13/25.
//

import Foundation
@testable import GMDB

class GMTempDB {
    let testDatabasePath = "/private/tmp/tmp.db"
    let populatedDatabasePath = "/private/tmp/tmp-populated.db"
    let db: GMDatabase

    init(populate: (GMDatabase) throws -> Void) {
        // Delete old populated database
        let fileManager = FileManager.default

        try? fileManager.removeItem(atPath: populatedDatabasePath)
        db = GMDatabase(path: populatedDatabasePath)
        db.open()
        try? populate(db)
//        db.close()
    }

    deinit {
        db.close()
    }
}
