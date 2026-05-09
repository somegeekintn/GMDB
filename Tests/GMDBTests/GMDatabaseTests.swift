//
//  GMDatabaseTests.swift
//  GMDB
//
//  Based on FMDB by August Mueller
//  Ported to Swift by Casey Fleser on 8/13/25.
//

import Testing
import Foundation
import SQLite3
@testable import GMDB

@Suite(.serialized) class GMDatabaseTests {
    let testDB = GMTempDB { db in
        try db.executeUpdate("create table test (a text, b text, c integer, d double, e double)")

        try db.beginTransaction()
        for i in 0..<20 {
            try db.executeUpdate("insert into test (a, b, c, d, e) values (?, ?, ?, ?, ?)",
                                 "hi'", // look!  I put in a ', and I'm not escaping it!
                                 "number \(i)",
                                 i,
                                 Date(),
                                 Float(2.2)
            )
        }
        try db.commit()

        try db.beginTransaction()
        for i in 0..<20 {
            try db.executeUpdate("insert into test (a, b, c, d, e) values (?, ?, ?, ?, ?)",
                                 "hi again'", // look!  I put in a ', and I'm not escaping it!
                                 "number \(i)",
                                 i,
                                 Date(),
                                 Float(2.2)
            )
        }
        try db.commit()

        try db.executeUpdate("create table t3 (a somevalue)")

        try db.beginTransaction()
        for i in 0..<20 {
            try db.executeUpdate("insert into t3 (a) values (?)", i)
        }
        try db.commit()
    }

    var db: GMDatabase { testDB.db }

    @Test func openWithVFS() {
        // create custom vfs
        let vfs = sqlite3_vfs_find(nil)

        "MyCustomVFS".withCString {
            vfs?.pointee.zName = $0

            #expect(sqlite3_vfs_register(vfs, 0) == 0)
            // use custom vfs to open a in memory database
            let db = GMDatabase(path: ":memory:")
            db.openWith(flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, vfs: "MyCustomVFS")
            #expect(!db.hadError, "Open with a custom VFS should have succeeded")
            #expect(sqlite3_vfs_unregister(vfs) == SQLITE_OK)
        }
    }

    @Test func urlOpen() {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = GMDatabase.databaseWithURL(fileURL)

        #expect(db.open(), "Open should succeed")
        #expect(db.databaseURL == fileURL)
        #expect(db.close(), "Close should succeed")

        try? FileManager.default.removeItem(at: fileURL)
    }

    @Test func failOnOpenWithUnknownVFS() {
        let db = GMDatabase(path: ":memory:")
        db.openWith(flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, vfs: "UnknownVFS")
        #expect(db.hadError, "Should have failed")
    }

    @Test func failOnUnopenedDatabase() {
        db.close()

        #expect(db.executeQuery("select * from table") == nil, "Shouldn't get results from an empty table")
        #expect(db.hadError, "Should have failed")
    }

    @Test func failOnBadStatement() {
        #expect(db.executeQuery("blah blah blah") == nil, "Invalid statement should fail")
        #expect(db.hadError, "Should have failed")
    }

    @Test func failOnBadStatementWithError() {
        #expect(throws: GMDBError.sql(SQLITE_ERROR, ""), "Error should be SQLITE_ERROR") {
            try self.db.executeUpdate("blah blah blah")
        }
    }

    @Test func pragmaJournalMode() {
        let ps = db.executeQuery("pragma journal_mode=delete")

        #expect(!db.hadError, "pragma should have succeeded")
        #expect(ps != nil, "Result set should be non-nil")
        #expect(ps?.next() == true, "Result set should have a next result")

        ps?.close()
    }

    @Test func pragmaPageSize() throws {
        try db.executeUpdate("PRAGMA page_size=2048")

        #expect(!db.hadError, "pragma should have succeeded")
    }

    @Test func vacuum() throws {
        try db.executeUpdate("VACUUM")

        #expect(!db.hadError, "VACUUM should have succeeded")
    }

    @Test func selectULL() throws {
        // Unsigned long long
        try db.executeUpdate("create table ull (a integer)")

        try db.executeUpdate("insert into ull (a) values (?)", UInt64.max)
        #expect(!db.hadError, "Shouldn't have any errors")

        let rs = try #require(db.executeQuery("select a from ull"), "Should have a non-nil result set")
        while rs.next() {
            #expect(rs.unsignedLongLongIntFor(columnIndex: 0) == UInt64.max)
            #expect(rs.unsignedLongLongIntFor(column: "a") == UInt64.max)
        }

        rs.close()
        #expect(!db.hasOpenResultSets, "Shouldn't have any open result sets")
        #expect(!db.hadError, "Shouldn't have any errors")
    }

    @Test func selectByColumnName() throws {
        let rs = try #require(db.executeQuery("select rowid,* from test where a = ?", "hi'"), "Should have a non-nil result set")

        while rs.next() {
            _ = rs.intFor(column: "c")
            #expect(rs.stringFor(column: "b") != nil, "Should have non-nil string for 'b'")
            #expect(rs.stringFor(column: "a") != nil, "Should have non-nil string for 'a'")
            #expect(rs.stringFor(column: "rowid") != nil, "Should have non-nil string for 'rowid'")
            #expect(rs.dateFor(column: "d") != nil, "Should have non-nil date for 'd'")
            _ = rs.doubleFor(column: "d")
            _ = rs.doubleFor(column: "e")

            #expect(rs.columnNameFor(columnIndex: 0) == "rowid", "Wrong column name for result set column number")
            #expect(rs.columnNameFor(columnIndex: 1) == "a",     "Wrong column name for result set column number")
        }

        rs.close()
        #expect(!db.hasOpenResultSets, "Shouldn't have any open result sets")
        #expect(!db.hadError, "Shouldn't have any errors")
    }

    @Test func InvalidColumnNames() throws {
        let rs = try #require(db.executeQuery("select rowid, a, b, c from test"), "Should have a non-nil result set")
        let invalidColumnName = "foobar"

        while rs.next() {
            #expect(rs[invalidColumnName] == nil, "Invalid column name should return nil")
            #expect(rs.stringFor(column: invalidColumnName) == nil, "Invalid column name should return nil")
            #expect(rs.utf8StringFor(column: invalidColumnName) == nil, "Invalid column name should return nil")
            #expect(rs.dateFor(column: invalidColumnName) == nil, "Invalid column name should return nil")
            #expect(rs.dataFor(column: invalidColumnName) == nil, "Invalid column name should return nil")
            #expect(rs.dataNoCopyFor(column: invalidColumnName) == nil, "Invalid column name should return nil")
            #expect(rs.objectFor(column: invalidColumnName) == nil, "Invalid column name should return nil")
        }

        rs.close()
        #expect(!db.hasOpenResultSets, "Shouldn't have any open result sets")
        #expect(!db.hadError, "Shouldn't have any errors")
    }

    @Test func busyRetryTimeout() throws {
        let dbPath = try #require(db.databasePath)
        try db.executeUpdate("create table t1 (a integer)")
        try db.executeUpdate("insert into t1 values (?)", 5)

        db.setMaxBusyRetryTimeInterval(2)

        let newDB = GMDatabase.databaseWithPath(dbPath)
        newDB.open()

        let rs = try #require(newDB.executeQuery("select rowid,* from test where a = ?", "hi'"))
        _ = rs.next() // just grab one... which will keep the db locked

        #expect(throws: GMDBError.sql(SQLITE_BUSY, ""), "SQLITE_BUSY should be the last error") {
            try self.db.executeUpdate("insert into t1 values (5)")
        }

        rs.close()
        newDB.close()

        #expect(try db.executeUpdate("insert into t1 values (5)"), "The database shouldn't be locked at this point")
    }

    @Test func caseSensitiveResultDictionary() throws {
        // case sensitive result dictionary test
        try db.executeUpdate("create table cs (aRowName integer, bRowName text)")
        try db.executeUpdate("insert into cs (aRowName, bRowName) values (?, ?)", 1, "hello")

        #expect(!db.hadError, "Shouldn't have any errors")

        let rs = try #require(db.executeQuery("select * from cs"))
        while rs.next() {
            let d = try #require(rs.resultDictionary(), "Should have a result dictionary")

            #expect(d["aRowName"] != nil, "aRowName should be non-nil")
            #expect(d["arowname"] == nil, "arowname should be nil")
            #expect(d["bRowName"] != nil, "bRowName should be non-nil")
            #expect(d["browname"] == nil, "browname should be nil")
        }

        rs.close()
        #expect(!db.hasOpenResultSets, "Shouldn't have any open result sets")
        #expect(!db.hadError, "Shouldn't have any errors")
    }

    @Test func boolInsert() throws {
        try db.executeUpdate("create table btest (aRowName integer)")
        try db.executeUpdate("insert into btest (aRowName) values (?)", true)

        #expect(!db.hadError, "Shouldn't have any errors")

        let rs = try #require(db.executeQuery("select * from btest"))

        while rs.next() {
            #expect(rs.boolFor(columnIndex: 0), "first column should be true.")
            #expect(rs.intFor(columnIndex: 0) == 1, "first column should be equal to 1")
        }

        rs.close()
        #expect(!db.hasOpenResultSets, "Shouldn't have any open result sets")
        #expect(!db.hadError, "Shouldn't have any errors")
    }

    @Test func namedParametersCount() throws {
        #expect(try db.executeUpdate("create table namedparamcounttest (a text, b text, c integer, d double)"))
        var dictionaryArgs: [String: Any] = ["a": "Text1", "b": "Text2", "c": 1, "d": Double(2.0)]

        #expect(try db.executeUpdate("insert into namedparamcounttest values (:a, :b, :c, :d)", parameterDictionary: dictionaryArgs))

        var rs = try #require(db.executeQuery("select * from namedparamcounttest"))

        #expect(rs.next())

        #expect(rs.stringFor(column: "a") == "Text1")
        #expect(rs.stringFor(column: "b") == "Text2")
        #expect(rs.intFor(column: "c") == 1)
        #expect(rs.doubleFor(column: "d") == 2.0)

        rs.close()

        // note that at this point, dictionaryArgs has way more values than we need, but the query should still work since
        // a is in there, and that's all we need.
        rs = try #require(db.executeQuery("select * from namedparamcounttest where a = :a", dictionary: dictionaryArgs))

        #expect(rs.next())
        rs.close()

        // ***** Please note the following codes *****

        dictionaryArgs = ["a": "NewText1", "b": "NewText2", "OneMore": "OneMoreText"]

        #expect(try db.executeUpdate("update namedparamcounttest set a = :a, b = :b where b = 'Text2'", parameterDictionary: dictionaryArgs))
    }

    @Test func blobs() throws {
        #expect(try db.executeUpdate("create table blobTable (a text, b blob)"))

        // let's read an image from safari's app bundle.
        let safariCompass = try Data(contentsOf: URL(filePath: "/Applications/Safari.app/Contents/Resources/AppIcon.icns"))

        #expect(try db.executeUpdate("insert into blobTable (a, b) values (?, ?)", "safari's compass", safariCompass))

        let rs = try #require(db.executeQuery("select b from blobTable where a = ?", "safari's compass"))
        #expect(rs.next())
        let readData = rs.dataFor(column: "b")!
        #expect(safariCompass == readData)

        // ye shall read the header for this function, or suffer the consequences.
        let readDataNoCopy = rs.dataNoCopyFor(column: "b")!
        #expect(safariCompass == readDataNoCopy)

        rs.close()
        #expect(!db.hasOpenResultSets, "Shouldn't have any open result sets")
        #expect(!db.hadError, "Shouldn't have any errors")
    }

    @Test func nullValues() throws {
        #expect(try db.executeUpdate("create table t2 (a integer, b integer)"))
        #expect(try db.executeUpdate("insert into t2 values (?, ?)", nil, 5), "Failed to insert a nil value")

        let rs = try #require(db.executeQuery("select * from t2"))

        while rs.next() {
            #expect(rs.stringFor(columnIndex: 0) == nil, "Wasn't able to retrieve a null string")
            #expect(rs.stringFor(columnIndex: 1) == "5")
        }

        rs.close()
        #expect(!db.hasOpenResultSets, "Shouldn't have any open result sets")
        #expect(!db.hadError, "Shouldn't have any errors")
    }

    @Test func nestedResultSets() throws {
        let rs = try #require(db.executeQuery("select * from t3"))
        while rs.next() {
            let foo = rs.intFor(columnIndex: 0)
            let newVal = foo + 100

            try db.executeUpdate("update t3 set a = ? where a = ?", newVal, foo)

            let rs2 = try #require(db.executeQuery("select a from t3 where a = ?", newVal))
            rs2.next()

            #expect(rs2.intFor(columnIndex: 0) == newVal)

            rs2.close()
        }

        rs.close()
        #expect(!db.hasOpenResultSets, "Shouldn't have any open result sets")
        #expect(!db.hadError, "Shouldn't have any errors")
    }

    @Test func nsNullInsertion() throws {
        #expect(try db.executeUpdate("create table nulltest (a text, b text)"))

        #expect(try db.executeUpdate("insert into nulltest (a, b) values (?, ?)", NSNull(), "a"))
        #expect(try db.executeUpdate("insert into nulltest (a, b) values (?, ?)", nil, "b"))

        let rs = try #require(db.executeQuery("select * from nulltest"))

        while rs.next() {
            #expect(rs.stringFor(columnIndex: 0) == nil)
            #expect(rs.stringFor(columnIndex: 1) != nil)
        }

        rs.close()
        #expect(!db.hasOpenResultSets, "Shouldn't have any open result sets")
        #expect(!db.hadError, "Shouldn't have any errors")
    }

    @Test func nullDates() throws {
        let date = Date()
        #expect(try db.executeUpdate("create table datetest (a double, b double, c double)"))
        #expect(try db.executeUpdate("insert into datetest (a, b, c) values (?, ?, 0)", NSNull(), date))

        let rs = try #require(db.executeQuery("select * from datetest"))

        while rs.next() {
            let b = try #require(rs.dateFor(columnIndex: 1))
            let c = try #require(rs.dateFor(columnIndex: 2), "zero date shouldn't be nil")

            #expect(rs.dateFor(columnIndex: 0) == nil)

            #expect(abs(b.timeIntervalSince(date)) < 1.0, "Dates should be the same to within a second")
            #expect(abs(c.timeIntervalSince1970) < 1.0, "Dates should be the same to within a second")
        }
        rs.close()

        #expect(!db.hasOpenResultSets, "Shouldn't have any open result sets")
        #expect(!db.hadError, "Shouldn't have any errors")
    }

    @Test func lotsOfNulls() throws {
        guard let safariCompass = try? Data(contentsOf: URL(filePath: "/Applications/Safari.app/Contents/Resources/compass.icns")) else { return }

        #expect(try db.executeUpdate("create table nulltest2 (s text, d data, i integer, f double, b integer)"))

        #expect(try db.executeUpdate("insert into nulltest2 (s, d, i, f, b) values (?, ?, ?, ?, ?)", "Hi", safariCompass, Int(12), Float(4.4), true))
        #expect(try db.executeUpdate("insert into nulltest2 (s, d, i, f, b) values (?, ?, ?, ?, ?)", nil, nil, nil, nil, NSNull()))

        let rs = try #require(db.executeQuery("select * from nulltest2"))
        while rs.next() {
            let i = rs.intFor(columnIndex: 2)

            if i == 12 {
                // it's the first row we inserted.
                #expect(!rs.columnIndexIsNull(columnIndex: 0))
                #expect(!rs.columnIndexIsNull(columnIndex: 1))
                #expect(!rs.columnIndexIsNull(columnIndex: 2))
                #expect(!rs.columnIndexIsNull(columnIndex: 3))
                #expect(!rs.columnIndexIsNull(columnIndex: 4))
                #expect(!rs.columnIndexIsNull(columnIndex: 5))

                #expect(rs.dataFor(column: "d") == safariCompass)
                #expect(rs.dataFor(column: "notthere") == nil)
                #expect(rs.stringFor(columnIndex: -2) == nil, "Negative columns should return nil results")
                #expect(rs.boolFor(columnIndex: 4))
                #expect(rs.boolFor(column: "b"))

                #expect(abs(4.4 - rs.doubleFor(column: "f")) < 0.0000001, "Saving a float and returning it as a double shouldn't change the result much")

                #expect(rs.intFor(column: "i") == 12)
                #expect(rs.intFor(columnIndex: 2) == 12)

                #expect(rs.intFor(columnIndex: 2) == 0, "Non-existent columns should return zero for ints")
                #expect(rs.intFor(column: "notthere") == 0, "Non-existent columns should return zero for ints")

                #expect(rs.longFor(column: "i") == 12)
                #expect(rs.longLongIntFor(column: "i") == 12)
            }
            else {
                // let's test various null things.

                #expect(rs.columnIndexIsNull(columnIndex: 0))
                #expect(rs.columnIndexIsNull(columnIndex: 1))
                #expect(rs.columnIndexIsNull(columnIndex: 2))
                #expect(rs.columnIndexIsNull(columnIndex: 3))
                #expect(rs.columnIndexIsNull(columnIndex: 4))
                #expect(rs.columnIndexIsNull(columnIndex: 5))

                #expect(rs.dataFor(column: "d") == nil)
            }
        }
        rs.close()

        #expect(!db.hasOpenResultSets, "Shouldn't have any open result sets")
        #expect(!db.hadError, "Shouldn't have any errors")
    }

    @Test func utf8Strings() throws {
        #expect(try db.executeUpdate("create table utest (a text)"))
        #expect(try db.executeUpdate("insert into utest values (?)", "/übertest"))

        let rs = try #require(db.executeQuery("select * from utest where a = ?", "/übertest"))
        #expect(rs.next())
        rs.close()
        #expect(!db.hasOpenResultSets, "Shouldn't have any open result sets")
        #expect(!db.hadError, "Shouldn't have any errors")
    }

    @Test func argumentsInArray() throws {
        #expect(try db.executeUpdate("create table testOneHundredTwelvePointTwo (a text, b integer)"))
        #expect(try db.executeUpdate("insert into testOneHundredTwelvePointTwo values (?, ?)", parameterArray: ["one", 2]))
        #expect(try db.executeUpdate("insert into testOneHundredTwelvePointTwo values (?, ?)", parameterArray: ["one", 3]))

        let rs = try #require(db.executeQuery("select * from testOneHundredTwelvePointTwo where b > ?", array: [1]))
        #expect(rs.next())

        #expect(rs.hasAnotherRow)
        #expect(!db.hadError)

        #expect(rs.stringFor(columnIndex: 0) == "one")
        #expect(rs.intFor(columnIndex: 1) == 2)

        #expect(rs.next())

        #expect(rs.intFor(columnIndex: 1) == 3)

        #expect(!rs.next())
        #expect(!rs.hasAnotherRow)
   }

    @Test func columnNamesContainingPeriods() throws {
        #expect(try db.executeUpdate("create table t4 (a text, b text)"))
        #expect(try db.executeUpdate("insert into t4 (a, b) values (?, ?)", "one", "two"))

        var rs = try #require(db.executeQuery("select t4.a as 't4.a', t4.b from t4;"))

        #expect(rs.next())

        #expect(rs.stringFor(column: "t4.a") == "one")
        #expect(rs.stringFor(column: "b") == "two")

        #expect(strcmp(rs.utf8StringFor(column: "b"), "two") == 0, "String comparison should return zero")

        rs.close()

        // let's try these again, with the withArgumentsInArray: variation
        #expect(try db.executeUpdate("drop table t4;", parameterArray: []))
        #expect(try db.executeUpdate("create table t4 (a text, b text)", parameterArray: []))

        try db.executeUpdate("insert into t4 (a, b) values (?, ?)", parameterArray: ["one", "two"])

        rs = try #require(db.executeQuery("select t4.a as 't4.a', t4.b from t4;", array: []))

        #expect(rs.next())

        #expect(rs.stringFor(column: "t4.a") == "one")
        #expect(rs.stringFor(column: "b") == "two")

        #expect(strcmp(rs.utf8StringFor(column: "b"), "two") == 0, "String comparison should return zero")

        rs.close()
    }

    @Test func formatStringParsing() throws {
        // Unsupported
//    XCTAssertTrue([self.db executeUpdate:@"create table t5 (a text, b int, c blob, d text, e text)"]);
//    [self.db executeUpdateWithFormat:@"insert into t5 values (%s, %d, %@, %c, %lld)", "text", 42, @"BLOB", 'd', 12345678901234ll];
//    
//    FMResultSet *rs = [self.db executeQueryWithFormat:@"select * from t5 where a = %s and a = %@ and b = %d", "text", @"text", 42];
//    XCTAssertNotNil(rs);
//    
//    XCTAssertTrue([rs next]);
//    
//    XCTAssertEqualObjects([rs stringForColumn:@"a"], @"text");
//    XCTAssertEqual([rs intForColumn:@"b"], 42);
//    XCTAssertEqualObjects([rs stringForColumn:@"c"], @"BLOB");
//    XCTAssertEqualObjects([rs stringForColumn:@"d"], @"d");
//    XCTAssertEqual([rs longLongIntForColumn:@"e"], 12345678901234ll);
//    
//    [rs close];
    }

    @Test func formatStringParsingWithSizePrefixes() throws {
        // Unsupported
//    XCTAssertTrue([self.db executeUpdate:@"create table t55 (a text, b int, c float)"]);
//    short testShort = -4;
//    float testFloat = 5.5;
//    [self.db executeUpdateWithFormat:@"insert into t55 values (%c, %hi, %g)", 'a', testShort, testFloat];
//    
//    unsigned short testUShort = 6;
//    [self.db executeUpdateWithFormat:@"insert into t55 values (%c, %hu, %g)", 'a', testUShort, testFloat];
//    
//    
//    FMResultSet *rs = [self.db executeQueryWithFormat:@"select * from t55 where a = %s order by 2", "a"];
//    XCTAssertNotNil(rs);
//    
//    XCTAssertTrue([rs next]);
//    
//    XCTAssertEqualObjects([rs stringForColumn:@"a"], @"a");
//    XCTAssertEqual([rs intForColumn:@"b"], -4);
//    XCTAssertEqualObjects([rs stringForColumn:@"c"], @"5.5");
//    
//    
//    XCTAssertTrue([rs next]);
//    
//    XCTAssertEqualObjects([rs stringForColumn:@"a"], @"a");
//    XCTAssertEqual([rs intForColumn:@"b"], 6);
//    XCTAssertEqualObjects([rs stringForColumn:@"c"], @"5.5");
//    
//    [rs close];
    }

    @Test func formatStringParsingWithNilValue() throws {
        // Unsupported
//    XCTAssertTrue([self.db executeUpdate:@"create table tatwhat (a text)"]);
//    
//    BOOL worked = [self.db executeUpdateWithFormat:@"insert into tatwhat values(%@)", nil];
//    
//    XCTAssertTrue(worked);
//    
//    FMResultSet *rs = [self.db executeQueryWithFormat:@"select * from tatwhat"];
//    XCTAssertNotNil(rs);
//    XCTAssertTrue([rs next]);
//    XCTAssertTrue([rs columnIndexIsNull:0]);
//    
//    XCTAssertFalse([rs next]);
    }

    @Test func updateWithErrorAndBindings() throws {
        var err: Error? = nil

        #expect(try db.executeUpdate("create table t5 (a text, b int, c blob, d text, e text)"))
        #expect(db.executeUpdate("insert into t5 values (?, ?, ?, ?, ?)", withError: &err, "text", 42, "BLOB", "d", 0))
    }

    @Test func selectWithEmptyArgumentsArray() throws {
        let rs = db.executeQuery("select * from test where a=?", array: [])
        #expect(rs == nil)
    }

    @Test func databaseAttach() throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: "/tmp/attachme.db")

        let dbB = GMDatabase(path: "/tmp/attachme.db")
        #expect(dbB.open())
        #expect(try dbB.executeUpdate("create table attached (a text)"))
        #expect(try dbB.executeUpdate("insert into attached values (?)", "test"))
        #expect(dbB.close())

        try db.executeUpdate("attach database '/tmp/attachme.db' as attack")

        let rs = try #require(db.executeQuery("select * from attack.attached"))
        #expect(rs.next())
        rs.close()
    }

    @Test func namedParameters() throws {
        // -------------------------------------------------------------------------------
        // Named parameters.
        #expect(try db.executeUpdate("create table namedparamtest (a text, b text, c integer, d double)"))
        var dictionaryArgs: [String: Any] = [:]
        dictionaryArgs["a"] = "Text1"
        dictionaryArgs["b"] = "Text2"
        dictionaryArgs["c"] = 1
        dictionaryArgs["d"] = 2.0
        #expect(try db.executeUpdate("insert into namedparamtest values (:a, :b, :c, :d)", parameterDictionary: dictionaryArgs))

        var rs = try #require(db.executeQuery("select * from namedparamtest"))
        #expect(rs.next())

        #expect(rs.stringFor(column: "a") == "Text1")
        #expect(rs.stringFor(column: "b") == "Text2")
        #expect(rs.intFor(column: "c") == 1)
        #expect(rs.doubleFor(column: "d") == 2.0)

        rs.close()

        dictionaryArgs.removeAll()

        dictionaryArgs["blah"] = "Text2"

        rs = try #require(db.executeQuery("select * from namedparamtest where b = :blah", dictionary: dictionaryArgs))
        #expect(rs.next())

        #expect(rs.stringFor(column: "b") == "Text2")

        rs.close()
    }

    @Test func pragmaDatabaseList() throws {
        let rs = try #require(db.executeQuery("pragma database_list"))
        var counter = 0
        while rs.next() {
            counter += 1
            #expect(rs.stringFor(column: "file") == db.databasePath)
        }
        #expect(counter == 1, "Only one database should be attached")
    }

    @Test func cachedStatementsInUse() throws {
        db.setShouldCacheStatements(true)

        #expect(try db.executeUpdate("CREATE TABLE testCacheStatements(key INTEGER PRIMARY KEY, value INTEGER)"))
        #expect(try db.executeUpdate("INSERT INTO testCacheStatements (key, value) VALUES (1, 2)"))
        #expect(try db.executeUpdate("INSERT INTO testCacheStatements (key, value) VALUES (2, 4)"))
        #expect(db.executeQuery("SELECT * FROM testCacheStatements WHERE key=1")?.next() == true)
        #expect(db.executeQuery("SELECT * FROM testCacheStatements WHERE key=1")?.next() == true)
    }

    @Test func statementCachingWorks() throws {
        #expect(try db.executeUpdate("CREATE TABLE testStatementCaching ( value INTEGER )"))
        #expect(try db.executeUpdate("INSERT INTO testStatementCaching( value ) VALUES (1)"))
        #expect(try db.executeUpdate("INSERT INTO testStatementCaching( value ) VALUES (1)"))
        #expect(try db.executeUpdate("INSERT INTO testStatementCaching( value ) VALUES (2)"))

        db.setShouldCacheStatements(true)

        // two iterations.
        //  the first time through no statements will be from the cache.
        //  the second time through all statements come from the cache.
        for i in 1...2 {
            let rs1 = try #require(db.executeQuery("SELECT rowid, * FROM testStatementCaching WHERE value = ?", 1)) // results in 2 rows...
            #expect(rs1.next())

            // confirm that we're seeing the benefits of caching.
            #expect(rs1.statement?.useCount == i)

            let rs2 = try #require(db.executeQuery("SELECT rowid, * FROM testStatementCaching WHERE value = ?", 2)) // results in 1 row
            #expect(rs2.next())
            #expect(rs2.statement?.useCount == i)

            // This is the primary check - with the old implementation of statement caching, rs2 would have rejiggered the (cached) statement used by rs1, making this test fail to return the 2nd row in rs1.
            #expect(rs1.next())

            rs1.close()
            rs2.close()
        }
    }

    @Test func dateFormat() throws {
        let testOneDateFormat = { (db: GMDatabase, testDate: Date) in
            try db.executeUpdate("DROP TABLE IF EXISTS test_format")
            try db.executeUpdate("CREATE TABLE test_format ( test TEXT )")
            try db.executeUpdate("INSERT INTO test_format(test) VALUES (?)", testDate)

            let rs = try #require(db.executeQuery("SELECT test FROM test_format", 1))
            #expect(rs.next())

            #expect(rs.dateFor(columnIndex: 0) == testDate)

            rs.close()
        }

        let fmt = GMDatabase.storeableDateFormat("yyyy-MM-dd HH:mm:ss")

        let testDate = try #require(fmt.date(from: "2013-02-20 12:00:00"))

        // test timestamp dates (ensuring our change does not break those)
        try testOneDateFormat(db, testDate)

        // now test the string-based timestamp
        db.setDateFormat(fmt)
        try testOneDateFormat(db, testDate)
    }

    @Test func columnNameMap() throws {
        #expect(try db.executeUpdate("create table colNameTest (a, b, c, d)"))
        #expect(try db.executeUpdate("insert into colNameTest values (1, 2, 3, 4)"))

        let ars = try #require(db.executeQuery("select * from colNameTest", 2))

        let d = ars.columnNameToIndexMap
        #expect(d.count == 4)

        #expect(d["a"] == 0)
        #expect(d["b"] == 1)
        #expect(d["c"] == 2)
        #expect(d["d"] == 3)
    }

    @Test func customStringFunction() throws {
        createCustomFunctions()

        let ars = try #require(db.executeQuery("SELECT RemoveDiacritics(?)", "José"))
        #expect(ars.next(), "Should have returned value")
        let result = ars.stringFor(columnIndex: 0)
        #expect(result == "Jose")
    }

    @Test func failCustomStringFunction() throws {
        createCustomFunctions()

        let ars = try #require(db.executeQuery("SELECT RemoveDiacritics(?)", Double.pi, "Prepare should have succeeded"))
        let result = Result { try ars.nextWithError() }

        switch result {
        case .success(let success):
            #expect(!success, "'next' should have failed")
        case .failure(let failure):
            #expect((failure as? GMDBError)?.localizedDescription == "Expected text")
        }

        #expect(db.executeQuery("SELECT RemoveDiacritics('jose','ortega')") == nil)
        let error = db.lastError
        #expect(error.localizedDescription.contains("wrong number of arguments") == true, "Should get wrong number of arguments error, but got '\(error.localizedDescription)'")
    }

    @Test func customDoubleFunction() throws {
        createCustomFunctions()

        let rs = try #require(db.executeQuery("SELECT Hypotenuse(?, ?)", 3.0, 4.0))
        #expect(rs.next(), "Should have returned value")
        let value = rs.doubleFor(columnIndex: 0)
        #expect(value == 5.0)
    }

    @Test func customIntFunction() throws {
        createCustomFunctions()

        let rs = try #require(db.executeQuery("SELECT Hypotenuse(?, ?)", 3, 4))
        #expect(rs.next(), "Should have returned value")
        let value = rs.intFor(columnIndex: 0)
        #expect(value == 5)
    }

    @Test func failCustomNumericFunction() throws {
        createCustomFunctions()

        let rs = try #require(db.executeQuery("SELECT Hypotenuse(?, ?)", "foo", "bar"))
        let result = Result { try rs.nextWithError() }

        switch result {
        case .success(let success):
            #expect(!success, "Should have failed")
        case .failure(let failure):
            #expect((failure as? GMDBError)?.localizedDescription == "Expected numeric")
        }

        #expect(db.executeQuery("SELECT Hypotenuse(?)", 3.0) == nil, "Should fail for wrong number of arguments")
        let error = db.lastError
        #expect(error.localizedDescription.contains("wrong number of arguments") == true, "Should get wrong number of arguments error, but got '\(error.localizedDescription)'")
    }

    @Test func customDataFunction() throws {
        createCustomFunctions()
        let data = Data((0..<256).map { UInt8($0) })

        let rs = try #require(db.executeQuery("SELECT SetAlternatingByteToOne(?)", data))
        #expect(rs.next(), "Should have returned value")
        let result = try #require(rs.dataFor(columnIndex: 0), "should have result")
        #expect(result.count == data.count)

        for i in 0..<data.count {
            if (i % 2 == 0) {
                #expect(result[i] == 1)
            }
            else {
                #expect(result[i] == i)
            }
        }
    }

    @Test func failCustomDataFunction() throws {
        createCustomFunctions()

        let rs = try #require(db.executeQuery("SELECT SetAlternatingByteToOne(?)", "foo"))
        let result = Result { try rs.nextWithError() }

        switch result {
        case .success(let success):
            #expect(!success, "Performing SetAlternatingByteToOne with string should fail")
        case .failure(let failure):
            #expect((failure as? GMDBError)?.localizedDescription == "Expected blob")
        }
    }

    @Test func customFunctionNullValues() throws {
        db.makeFunction(named: "FunctionThatDoesntTestTypes", arguments: 1) { (context, argc, argv) in
            let data = self.db.valueData(argv[0])
            #expect(data == nil)
            let string = self.db.valueString(argv[0])
            #expect(string == nil)
            let intValue = self.db.valueInt(argv[0])
            #expect(intValue == 0)
            let longValue = self.db.valueLong(argv[0])
            #expect(longValue == 0)
            let doubleValue = self.db.valueDouble(argv[0])
            #expect(doubleValue == 0.0)

            self.db.resultInt(42, in: context)
        }

        let rs = try #require(db.executeQuery("SELECT FunctionThatDoesntTestTypes(?)", NSNull()))
        #expect(rs.next(), "Performing query should succeed")
    }

    @Test func customFunctionIntResult() throws {
        db.makeFunction(named: "IntResultFunction", arguments: 0) { (context, argc, argv) in
            self.db.resultInt(42, in: context)
        }

        let rs = try #require(db.executeQuery("SELECT IntResultFunction()"), "Creating query should succeed")
        #expect(rs.next(), "Performing query should succeed")

        #expect(rs.intFor(columnIndex: 0) == 42)
    }

    @Test func customFunctionLongResult() throws {
        db.makeFunction(named: "LongResultFunction", arguments: 0) { (context, argc, argv) in
            self.db.resultLong(42, in: context)
        }

        let rs = try #require(db.executeQuery("SELECT LongResultFunction()"), "Creating query should succeed")
        #expect(rs.next(), "Performing query should succeed")

        #expect(rs.longFor(columnIndex: 0) == 42)
    }

    @Test func customFunctionDoubleResult() throws {
        db.makeFunction(named: "DoubleResultFunction", arguments: 0) { (context, argc, argv) in
            self.db.resultDouble(0.1, in: context)
        }

        let rs = try #require(db.executeQuery("SELECT DoubleResultFunction()"), "Creating query should succeed")
        #expect(rs.next(), "Performing query should succeed")

        #expect(rs.doubleFor(columnIndex: 0) == 0.1)
    }

    @Test func customFunctionNullResult() throws {
        db.makeFunction(named: "NullResultFunction", arguments: 0) { (context, argc, argv) in
            self.db.resultNull(in: context)
        }

        let rs = try #require(db.executeQuery("SELECT NullResultFunction()"), "Creating query should succeed")
        #expect(rs.next(), "Performing query should succeed")

        #expect((rs.objectFor(columnIndex: 0) as? NSNull) == NSNull())
    }

    @Test func customFunctionErrorResult() throws {
        db.makeFunction(named: "ErrorResultFunction", arguments: 0) { (context, argc, argv) in
            self.db.resultError("foo", in: context)
            self.db.resultErrorCode(42, in: context)
        }

        let rs = try #require(db.executeQuery("SELECT ErrorResultFunction()"), "Creating query should succeed")
        #expect(!rs.next(), "Performing query should fail.")

        #expect(db.lastErrorMessage == "foo")
        #expect(db.lastErrorCode == 42)
    }

    @Test func customFunctionTooBigErrorResult() throws {
        db.makeFunction(named: "TooBigErrorResultFunction", arguments: 0) { (context, argc, argv) in
            self.db.resultErrorTooBig(in: context)
        }

        let rs = try #require(db.executeQuery("SELECT TooBigErrorResultFunction()"), "Creating query should succeed")
        #expect(!rs.next(), "Performing query should fail.")

        #expect(db.lastErrorMessage == "string or blob too big")
        #expect(db.lastErrorCode == SQLITE_TOOBIG)
    }

    @Test func customFunctionNoMemoryErrorResult() throws {
        db.makeFunction(named: "NoMemoryErrorResultFunction", arguments: 0) { (context, argc, argv) in
            self.db.resultErrorNoMemory(in: context)
        }

        let rs = try #require(db.executeQuery("SELECT NoMemoryErrorResultFunction()"), "Creating query should succeed")
        #expect(!rs.next(), "Performing query should fail.")

        #expect(db.lastErrorMessage == "out of memory")
        #expect(db.lastErrorCode == SQLITE_NOMEM)
    }

    @Test func userVersion() throws {
        #expect(GMDatabase.GMDBUserVersion.compare("0.1.1", options: .numeric) == .orderedSame)
    }

    @Test func versionStringAboveRequired() throws {
        #expect(GMDatabase.GMDBUserVersion.compare("0.0.42", options: .numeric) == .orderedDescending)
    }

    @Test func versionStringBelowRequired() throws {
        #expect(GMDatabase.GMDBUserVersion.compare("10.0.42", options: .numeric) == .orderedAscending)
    }

    @Test func executeStatements() throws {
        var sql = """
        create table bulktest1 (id integer primary key autoincrement, x text);
        create table bulktest2 (id integer primary key autoincrement, y text);
        create table bulktest3 (id integer primary key autoincrement, z text);
        insert into bulktest1 (x) values ('XXX');
        insert into bulktest2 (y) values ('YYY');
        insert into bulktest3 (z) values ('ZZZ');
        """

        #expect(db.executeStatements(sql), "bulk create")

        sql = """
        select count(*) as count from bulktest1;
        select count(*) as count from bulktest2;
        select count(*) as count from bulktest3;
        """

        var success = db.executeStatements(sql) { dict in
            #expect(dict["count"].map(Int.init) == 1)
            return 0
        }
        #expect(success, "bulk select")

        // select blob type records
        try db.executeUpdate("create table bulktest4 (id integer primary key autoincrement, b blob);")
        let blobData = try Data(contentsOf: URL(fileURLWithPath: "/bin/bash"))
        try db.executeUpdate("insert into bulktest4 (b) values (?)", parameterArray: [blobData])

        sql = "select * from bulktest4"
        success = db.executeStatements(sql) { dict in
            return 0
        }
        #expect(success, "bulk select")

        sql = """
        drop table bulktest1;
        drop table bulktest2;
        drop table bulktest3;
        drop table bulktest4;
        """

        success = db.executeStatements(sql)

        #expect(success, "bulk drop")
    }

    @Test func charAndBoolTypes() throws {
        let asciiX = Character("x").asciiValue ?? 0

        #expect(try db.executeUpdate("create table charBoolTest (a, b, c)"))

        #expect(try db.executeUpdate("insert into charBoolTest values (?, ?, ?)", true, false, asciiX))

        let rs = try #require(db.executeQuery("select * from charBoolTest"))

        #expect(rs.next())

        #expect(rs.boolFor(column: "a") == true)
//        #expect(rs.objectFor(column: "a") == true)

        #expect(rs.boolFor(column: "b") == false)
//        #expect(rs.objectFor(column: "b") == false)

        #expect(rs.intFor(column: "c") == asciiX)
//        #expect(rs.objectFor(column: "c") == asciiX)

        rs.close()

        #expect(try db.executeUpdate("drop table charBoolTest"), "Did not drop table")
    }

    @Test func sqliteLibVersion() throws {
        let version = GMDatabase.sqliteLibVersion
        #expect(version.compare("3.7", options: .numeric) == .orderedDescending, "earlier than 3.7")
        #expect(version.compare("4.0", options: .numeric) == .orderedAscending, "not earlier than 4.0")
    }

    @Test func isThreadSafe() throws {
        let isThreadSafe = GMDatabase.isSQLiteThreadSafe
        #expect(isThreadSafe, "not threadsafe")
    }

    @Test func openNilPath() throws {
        let db = GMDatabase()
        #expect(db.open())
        #expect(try db.executeUpdate("create table foo (bar text)"), "create failed")
        let value = "baz"
        #expect(try db.executeUpdate("insert into foo (bar) values (?)", parameterArray: [value]), "insert failed")
        let retrievedValue = db.string(for: "select bar from foo") ?? ""
        #expect(value.compare(retrievedValue) == .orderedSame, "values didn't match")
    }

    @Test func openZeroLengthPath() throws {
        let db = GMDatabase(path: "")
        #expect(db.open(), "open failed")
        #expect(try db.executeUpdate("create table foo (bar text)"), "create failed")
        let value = "baz"
        #expect(try db.executeUpdate("insert into foo (bar) values (?)", parameterArray: [value]), "insert failed")
        let retrievedValue = db.string(for: "select bar from foo") ?? ""
        #expect(value.compare(retrievedValue) == .orderedSame, "values didn't match")
    }

    @Test func openTwice() throws {
        let db = GMDatabase()
        db.open()
        #expect(db.open(), "Double open failed")
    }

    @Test func invalid() throws {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let path = documentsPath.appending("/nonexistentfolder/test.sqlite")

        let db = GMDatabase(path: path)
        #expect(!db.open(), "open did NOT fail")
    }

    @Test func changingMaxBusyRetryTimeInterval() throws {
        let db = GMDatabase()
        #expect(db.open(), "open failed")

        let originalInterval = db.maxBusyRetryTimeInterval
        let updatedInterval = originalInterval > 0 ? originalInterval + 1 : 1

        db.setMaxBusyRetryTimeInterval(updatedInterval)
        let diff = abs(db.maxBusyRetryTimeInterval - updatedInterval)

        #expect(diff < 1e-5, "interval should have changed \(diff)")
    }

    @Test func changingMaxBusyRetryTimeIntervalDatabaseNotOpened() throws {
        let db = GMDatabase()
        // #expect(db.open(), "open failed")    // deliberately not opened

        let originalInterval = db.maxBusyRetryTimeInterval
        let updatedInterval = originalInterval > 0 ? originalInterval + 1 : 1

        db.setMaxBusyRetryTimeInterval(updatedInterval)
        #expect(originalInterval == db.maxBusyRetryTimeInterval, "interval should not have changed")
    }

    @Test func zeroMaxBusyRetryTimeInterval() throws {
        let db = GMDatabase()
         #expect(db.open(), "open failed")

        let updatedInterval = TimeInterval(0)

        db.setMaxBusyRetryTimeInterval(updatedInterval)
        #expect(updatedInterval == db.maxBusyRetryTimeInterval, "busy handler not disabled")
    }

    @Test func closeOpenResultSets() throws {
        let db = GMDatabase()
        #expect(db.open(), "open failed")
        #expect(try db.executeUpdate("create table foo (bar text)", "create failed"))
        let value = "baz"
        #expect(try db.executeUpdate("insert into foo (bar) values (?)", parameterArray: [value]), "insert failed")
        let rs = try #require(db.executeQuery("select bar from foo", "step failed"))
        db.closeOpenResultSets()
        #expect(!rs.next(), "step should have failed")
    }

    @Test func goodConnection() throws {
        let db = GMDatabase()
        #expect(db.open(), "open failed")
        #expect(db.goodConnection(), "no good connection")
    }

    @Test func badConnection() throws {
        let db = GMDatabase()
        // #expect(db.open(), "open failed")    // deliberately did not open
        #expect(!db.goodConnection(), "good connection")
    }

    @Test func lastRowId() throws {
        let db = GMDatabase()
        #expect(db.open(), "open failed")
        #expect(try db.executeUpdate("create table foo (foo_id integer primary key autoincrement, bar text)", "create failed"))

        #expect(try db.executeUpdate("insert into foo (bar) values (?)", parameterArray: ["baz"]), "insert failed")
        let firstRowId = db.lastInsertRowId()

        #expect(try db.executeUpdate("insert into foo (bar) values (?)", parameterArray: ["qux"]), "insert failed")
        let secondRowId = db.lastInsertRowId()

        #expect(secondRowId - firstRowId == 1, "rowid should have incremented")
    }

    @Test func changes() throws {
        let db = GMDatabase()
        #expect(db.open(), "open failed")
        #expect(try db.executeUpdate("create table foo (foo_id integer primary key autoincrement, bar text)", "create failed"))

        #expect(try db.executeUpdate("insert into foo (bar) values (?)", parameterArray: ["baz"]), "insert failed")
        #expect(try db.executeUpdate("insert into foo (bar) values (?)", parameterArray: ["qux"]), "insert failed")
        #expect(try db.executeUpdate("update foo set bar = ?", parameterArray: ["xxx"]), "insert failed")
        let changes = db.changes()

        #expect(changes == 2, "two rows should have incremented \(changes)")
    }

    @Test func bind() throws {
        let db = GMDatabase()
        #expect(db.open(), "open failed")
        #expect(try db.executeUpdate("create table foo (id integer primary key autoincrement, a numeric)", "create failed"))

        var insertedValue: NSNumber
        var retrievedValue: NSNumber

        insertedValue = NSNumber(value: CChar(51))
        #expect(try db.executeUpdate("insert into foo (a) values (?)", parameterArray: [insertedValue]), "insert failed")
        retrievedValue = NSNumber(value: db.int(for: "select a from foo where id = ?", db.lastInsertRowId()))
        #expect(insertedValue == retrievedValue, "values don't match")

        insertedValue = NSNumber(value: UInt8(52))
        #expect(try db.executeUpdate("insert into foo (a) values (?)", parameterArray: [insertedValue]), "insert failed")
        retrievedValue = NSNumber(value: db.int(for: "select a from foo where id = ?", db.lastInsertRowId()))
        #expect(insertedValue == retrievedValue, "values don't match")

        insertedValue = NSNumber(value: Int16(53))
        #expect(try db.executeUpdate("insert into foo (a) values (?)", parameterArray: [insertedValue]), "insert failed")
        retrievedValue = NSNumber(value: db.int(for: "select a from foo where id = ?", db.lastInsertRowId()))
        #expect(insertedValue == retrievedValue, "values don't match")

        insertedValue = NSNumber(value: UInt16(54))
        #expect(try db.executeUpdate("insert into foo (a) values (?)", parameterArray: [insertedValue]), "insert failed")
        retrievedValue = NSNumber(value: db.int(for: "select a from foo where id = ?", db.lastInsertRowId()))
        #expect(insertedValue == retrievedValue, "values don't match")

        insertedValue = NSNumber(value: Int(54))
        #expect(try db.executeUpdate("insert into foo (a) values (?)", parameterArray: [insertedValue]), "insert failed")
        retrievedValue = NSNumber(value: db.long(for: "select a from foo where id = ?", db.lastInsertRowId()))
        #expect(insertedValue == retrievedValue, "values don't match")

        insertedValue = NSNumber(value: UInt(55))
        #expect(try db.executeUpdate("insert into foo (a) values (?)", parameterArray: [insertedValue]), "insert failed")
        retrievedValue = NSNumber(value: db.long(for: "select a from foo where id = ?", db.lastInsertRowId()))
        #expect(insertedValue == retrievedValue, "values don't match")

        insertedValue = NSNumber(value: Int32(56))
        #expect(try db.executeUpdate("insert into foo (a) values (?)", parameterArray: [insertedValue]), "insert failed")
        retrievedValue = NSNumber(value: db.long(for: "select a from foo where id = ?", db.lastInsertRowId()))
        #expect(insertedValue == retrievedValue, "values don't match")

        insertedValue = NSNumber(value: UInt32(57))
        #expect(try db.executeUpdate("insert into foo (a) values (?)", parameterArray: [insertedValue]), "insert failed")
        retrievedValue = NSNumber(value: db.long(for: "select a from foo where id = ?", db.lastInsertRowId()))
        #expect(insertedValue == retrievedValue, "values don't match")

        insertedValue = NSNumber(value: Float(58))
        #expect(try db.executeUpdate("insert into foo (a) values (?)", parameterArray: [insertedValue]), "insert failed")
        retrievedValue = NSNumber(value: db.double(for: "select a from foo where id = ?", db.lastInsertRowId()))
        #expect(insertedValue == retrievedValue, "values don't match")

        insertedValue = NSNumber(value: Double(59))
        #expect(try db.executeUpdate("insert into foo (a) values (?)", parameterArray: [insertedValue]), "insert failed")
        retrievedValue = NSNumber(value: db.double(for: "select a from foo where id = ?", db.lastInsertRowId()))
        #expect(insertedValue == retrievedValue, "values don't match")

        insertedValue = NSNumber(value: true)
        #expect(try db.executeUpdate("insert into foo (a) values (?)", parameterArray: [insertedValue]), "insert failed")
        retrievedValue = NSNumber(value: db.bool(for: "select a from foo where id = ?", db.lastInsertRowId()))
        #expect(insertedValue == retrievedValue, "values don't match")
    }

    @Test func formatStrings() throws {
        // Unsupported
//    FMDatabase *db = [[FMDatabase alloc] init];
//    XCTAssert([db open], @"open failed");
//    XCTAssert([db executeUpdate:@"create table foo (id integer primary key autoincrement, a numeric)"], @"create failed");
//    
//    BOOL success;
//    
//    char insertedChar = 'A';
//    success = [db executeUpdateWithFormat:@"insert into foo (a) values (%c)", insertedChar];
//    XCTAssert(success, @"insert failed");
//    const char *retrievedChar = [[db stringForQuery:@"select a from foo where id = ?", @([db lastInsertRowId])] UTF8String];
//    XCTAssertEqual(insertedChar, retrievedChar[0], @"values don't match");
//    
//    const char *insertedString = "baz";
//    success = [db executeUpdateWithFormat:@"insert into foo (a) values (%s)", insertedString];
//    XCTAssert(success, @"insert failed");
//    const char *retrievedString = [[db stringForQuery:@"select a from foo where id = ?", @([db lastInsertRowId])] UTF8String];
//    XCTAssert(strcmp(insertedString, retrievedString) == 0, @"values don't match");
//    
//    int insertedInt = 42;
//    success = [db executeUpdateWithFormat:@"insert into foo (a) values (%d)", insertedInt];
//    XCTAssert(success, @"insert failed");
//    int retrievedInt = [db intForQuery:@"select a from foo where id = ?", @([db lastInsertRowId])];
//    XCTAssertEqual(insertedInt, retrievedInt, @"values don't match");
//
//    char insertedUnsignedInt = 43;
//    success = [db executeUpdateWithFormat:@"insert into foo (a) values (%u)", insertedUnsignedInt];
//    XCTAssert(success, @"insert failed");
//    char retrievedUnsignedInt = [db intForQuery:@"select a from foo where id = ?", @([db lastInsertRowId])];
//    XCTAssertEqual(insertedUnsignedInt, retrievedUnsignedInt, @"values don't match");
//    
//    float insertedFloat = 44;
//    success = [db executeUpdateWithFormat:@"insert into foo (a) values (%f)", insertedFloat];
//    XCTAssert(success, @"insert failed");
//    float retrievedFloat = [db doubleForQuery:@"select a from foo where id = ?", @([db lastInsertRowId])];
//    XCTAssertEqual(insertedFloat, retrievedFloat, @"values don't match");
//    
//    unsigned long long insertedUnsignedLongLong = 45;
//    success = [db executeUpdateWithFormat:@"insert into foo (a) values (%llu)", insertedUnsignedLongLong];
//    XCTAssert(success, @"insert failed");
//    unsigned long long retrievedUnsignedLongLong = [db longForQuery:@"select a from foo where id = ?", @([db lastInsertRowId])];
//    XCTAssertEqual(insertedUnsignedLongLong, retrievedUnsignedLongLong, @"values don't match");
    }

    @Test func stepError() throws {
        let db = GMDatabase()
        #expect(db.open(), "open failed")
        #expect(try db.executeUpdate("create table foo (id integer primary key)"))
        #expect(try db.executeUpdate("insert into foo (id) values (?)", parameterArray: [1]), "insert failed")

        var err: Error? = nil
        let success = db.executeUpdate("insert into foo (id) values (?)", withError: &err, 1)
        #expect(!success, "insert of duplicate key should have failed")
        #expect(err != nil, "error object should have been generated")
        #expect(db.lastErrorCode == 19, "error code 19 should have been generated")
    }

    @Test func checkpoint() throws {
        let db = GMDatabase()
        #expect(db.open(), "open failed")
        #expect(try db.executeUpdate("create table foo (id integer primary key)"))
        #expect(try db.executeUpdate("insert into foo (id) values (?)", parameterArray: [1]), "insert failed")

        var frameCount = Int32(0)
        var checkpointCount = Int32(0)
        try db.checkpoint(checkpointMode: .truncate, logFrameCount: &frameCount, checkpointCount: &checkpointCount)
        // Verify that we're calling the checkpoint interface, which is a decent scope for this test, without going so far as to verify what checkpoint does
        #expect(frameCount == -1, "frameCount should be -1 (means not using WAL mode) to verify that we're using the proper checkpoint interface")
        #expect(checkpointCount == -1, "checkpointCount should be -1 (means not using WAL mode) to verify that we're using the proper checkpoint interface")
    }

    @Test func immediateTransaction() throws {
        let db = GMDatabase()
        #expect(db.open(), "open failed")
        try db.beginImmediateTransaction()
        #expect(throws: (any Error).self) { try db.beginImmediateTransaction() }

        // Verify that beginImmediateTransaction behaves as advertised and starts a transaction
        #expect(db.lastErrorMessage == "cannot start a transaction within a transaction")
    }

    @Test func openFailure() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let fileURL1 = tempURL.appendingPathComponent(UUID().uuidString)
        let fileURL2 = tempURL.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default

        // ok, first create one database

        var db = GMDatabase(url: fileURL1)
        #expect(db.open(), "Database not created correctly for purposes of test")
        #expect(try db.executeUpdate("create table if not exists foo (bar text)"), "Table not created correctly for purposes of test")
        db.close()

        // now, try to create open second database even though it doesn't exist
        db = GMDatabase(url: fileURL2)
        #expect(!db.openWith(flags: SQLITE_OPEN_READWRITE), "Opening second database file that doesn't exist should not have succeeded")

        // OK, everything so far is fine, opening a db without CREATE option above should have failed,
        // but so fix the missing file issue and re-opening

        #expect(throws: Never.self, "Copying of db should have succeeded") { try manager.copyItem(at: fileURL1, to: fileURL2) }

        // now let's try opening it again

        #expect(db.openWith(flags: SQLITE_OPEN_READWRITE), "Opening second database should now succeed")

        // now let's try using it
        let rs = try #require(db.executeQuery("select * from foo"), "Should successfully be able to use re-opened database")

        // let's clean up
        rs.close()
        db.close()
        try? manager.removeItem(at: fileURL1)
        try? manager.removeItem(at: fileURL2)
    }

    @Test func transient() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let fileURL = tempURL.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default

        // ok, first create one database

        let db = GMDatabase(url: fileURL)
        #expect(db.open(), "Database not created correctly for purposes of test")
        #expect(try db.executeUpdate("CREATE TABLE IF NOT EXISTS foo (bar BLOB)"), "Table created correctly for purposes of test")

        let value = 42
        #expect(try utility1ForTestTransient(db: db, with: value), "INSERT failed")

        let rs = try #require(try utility2ForTestTransient(db: db, with: value), "Creating SELECT failed")

        // the following is the key test, namely if FMDB uses SQLITE_STATIC, the following may fail, but SQLITE_TRANSIENT ensures it will succeed

        #expect(utility3ForTestTransient(rs: rs, with: value), "Performing SELECT failed")

        // let's clean up

        rs.close()
        db.close()
        try? manager.removeItem(at: fileURL)
    }

    @Test func bindFailure() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let fileURL = tempURL.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default

        // ok, first create one database

        let db = GMDatabase(url: fileURL)
        #expect(db.open(), "Database not created correctly for purposes of test")
        #expect(try db.executeUpdate("CREATE TABLE IF NOT EXISTS foo (bar BLOB)"), "Table created correctly for purposes of test")

        let limit = db.limit(for: SQLITE_LIMIT_LENGTH, value: -1) + 1
        let data = Data(count: Int(limit))
        #expect(throws: (any Error).self, "Table created correctly for purposes of test") { try db.executeUpdate("INSERT INTO foo (bar) VALUES (?)", data) }

        // let's clean up

        db.close()
        try? manager.removeItem(at: fileURL)
    }

    @Test func rebindingWithDictionary() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let fileURL = tempURL.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default
        try? manager.removeItem(at: fileURL)

        // ok, first create one database

        let db = GMDatabase(url: fileURL)
        #expect(db.open(), "Database not created correctly for purposes of test")
        #expect(try db.executeUpdate("CREATE TABLE IF NOT EXISTS foo (id INTEGER PRIMARY KEY, bar TEXT)"), "Table created correctly for purposes of test")

        var rs = try #require(db.prepare("INSERT INTO foo (bar) VALUES (:bar)"), "INSERT statement not prepared \(db.lastErrorMessage)")

        let value1 = "foo"
        #expect(rs.bind(with: ["bar" : value1]), "Unable to bind")
        #expect(try rs.step(), "Performing query failed")

        let value2 = "bar"
        #expect(rs.bind(with: ["bar" : value2]), "Unable to bind")
        #expect(try rs.step(), "Performing query failed")

        #expect(rs.bind(with: ["bar" : value2]), "Unable to bind")
        #expect(try rs.step(), "Performing query failed")

        rs.close()

        rs = try #require(db.prepare("SELECT bar FROM foo WHERE bar = :bar"))
        #expect(rs.bind(with: ["bar" : value1]), "Unable to bind")
        #expect(rs.next(), "No record found")
        #expect(rs.stringFor(columnIndex: 0) == value1)
        #expect(!rs.next(), "There should have been only one record")

        #expect(rs.bind(with: ["bar" : value2]), "Unable to bind")
        #expect(rs.next(), "No record found")
        #expect(rs.stringFor(columnIndex: 0) == value2)
        #expect(rs.next(), "No record found")
        #expect(rs.stringFor(columnIndex: 0) == value2)
        #expect(!rs.next(), "There should have been only two record")

        // let's clean up

        rs.close()
        db.close()
        try? manager.removeItem(at: fileURL)
    }

    @Test func rebindingWithArray() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let fileURL = tempURL.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default

        // ok, first create one database

        let db = GMDatabase(url: fileURL)
        #expect(db.open(), "Database not created correctly for purposes of test")
        #expect(try db.executeUpdate("CREATE TABLE IF NOT EXISTS foo (id INTEGER PRIMARY KEY, bar TEXT)"), "Table created correctly for purposes of test")

        var rs = try #require(db.prepare("INSERT INTO foo (bar) VALUES (?)"), "INSERT statement not prepared \(db.lastErrorMessage)")

        let value1 = "foo"
        #expect(rs.bind(with: [value1]), "Unable to bind")
        #expect(try rs.step(), "Performing INSERT 1 failed")

        let value2 = "bar"
        #expect(rs.bind(with: [value2]), "Unable to bind")
        #expect(try rs.step(), "Performing INSERT 2 failed")
        #expect(rs.bind(with: [value2]), "Unable to bind")
        #expect(try rs.step(), "Performing INSERT 2 failed")

        rs.close()

        rs = try #require(db.prepare("SELECT bar FROM foo WHERE bar = ?"))
        #expect(rs.bind(with: [value1]), "Unable to bind")
        #expect(rs.next(), "No record found")
        #expect(rs.stringFor(columnIndex: 0) == value1)
        #expect(!rs.next(), "There should have been only one record")

        #expect(rs.bind(with: [value2]), "Unable to bind")
        #expect(rs.next(), "No record found")
        #expect(rs.stringFor(columnIndex: 0) == value2)
        #expect(rs.next(), "No record found")
        #expect(rs.stringFor(columnIndex: 0) == value2)
        #expect(!rs.next(), "There should have been only two record")

        // let's clean up

        rs.close()
        db.close()
        try? manager.removeItem(at: fileURL)
    }
}

extension GMDatabaseTests {
    func createCustomFunctions() {
        db.makeFunction(named: "RemoveDiacritics", arguments: 1) { (context, argc, argv) in
            let type = self.db.valueType(argv[0])
            if type == .null {
                self.db.resultNull(in: context)
                return
            }
            if type != .text {
                self.db.resultError("Expected text", in: context)
                return
            }
            if let string = self.db.valueString(argv[0]) {
                let result = string.folding(options: [.diacriticInsensitive], locale: nil)
                self.db.resultString(result, in: context)
            }
            else {
                self.db.resultError("Unable to get string", in: context)
            }
        }

        db.makeFunction(named: "Hypotenuse", arguments: 2) { (context, argc, argv) in
            let type1 = self.db.valueType(argv[0])
            let type2 = self.db.valueType(argv[1])

            if (type1 != .float && type1 != .integer && type2 != .float && type2 != .integer) {
                self.db.resultError("Expected numeric", in: context)
                return
            }
            let value1 = self.db.valueDouble(argv[0])
            let value2 = self.db.valueDouble(argv[1])
            self.db.resultDouble(hypot(value1, value2), in: context)
        }

        db.makeFunction(named: "SetAlternatingByteToOne", arguments: 1) { (context, argc, argv) in
            let type = self.db.valueType(argv[0])
            if (type != .blob) {
                self.db.resultError("Expected blob", in: context)
                return
            }
            if var data = self.db.valueData(argv[0]) {
                for i in stride(from: 0, to: data.count, by: 2) {
                    data[i] = 1
                }
                self.db.resultData(data, in: context)
            }
            else {
                self.db.resultError("Unable to get data", in: context)
            }
        }
    }

    // These three utility methods used by `testTransient`, to illustrate dangers of SQLITE_STATIC

    func utility1ForTestTransient(db: GMDatabase, with value: Int) throws -> Bool {
        let string = "value \(value)"

        return try db.executeUpdate("INSERT INTO foo (bar) VALUES (?)", string.data(using: .utf8))
    }

    func utility2ForTestTransient(db: GMDatabase, with value: Int) throws -> GMResultSet? {
        let string = "value \(value)"

        return db.executeQuery("SELECT * FROM foo WHERE bar = ?", string.data(using: .utf8))
    }

    func utility3ForTestTransient(rs: GMResultSet, with value: Int) -> Bool {
        let string = "xxxxx \(value + 1)"
        print(string)   // Just to ensure the above isn't optimized out
        return rs.next()
    }
}
