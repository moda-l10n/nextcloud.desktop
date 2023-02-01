/*
 * Copyright (C) 2022 by Claudio Cambra <claudio.cambra@nextcloud.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

import Foundation
import RealmSwift
import FileProvider
import NextcloudKit

class NextcloudFilesDatabaseManager : NSObject {
    static let shared = {
        return NextcloudFilesDatabaseManager();
    }()

    let relativeDatabaseFolderPath = "Database/"
    let databaseFilename = "fileproviderextdatabase.realm"
    let relativeDatabaseFilePath: String
    var databasePath: URL?

    let schemaVersion: UInt64 = 100

    override init() {
        self.relativeDatabaseFilePath = self.relativeDatabaseFolderPath + self.databaseFilename

        guard let fileProviderDataDirUrl = pathForFileProviderExtData() else {
            super.init()
            return
        }

        self.databasePath = fileProviderDataDirUrl.appendingPathComponent(self.relativeDatabaseFilePath)

        // Disable file protection for directory DB
        // https://docs.mongodb.com/realm/sdk/ios/examples/configure-and-open-a-realm/#std-label-ios-open-a-local-realm
        let dbFolder = fileProviderDataDirUrl.appendingPathComponent(self.relativeDatabaseFolderPath)
        let dbFolderPath = dbFolder.path
        do {
            try FileManager.default.createDirectory(at: dbFolder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dbFolderPath)
        } catch let error {
            NSLog("Could not set permission level for File Provider database folder, received error: %@", error.localizedDescription)
        }

        let config = Realm.Configuration(
            fileURL: self.databasePath,
            schemaVersion: self.schemaVersion,
            objectTypes: [NextcloudItemMetadataTable.self, NextcloudDirectoryMetadataTable.self, NextcloudLocalFileMetadataTable.self]
        )

        Realm.Configuration.defaultConfiguration = config

        do {
            let realm = try Realm()
            NSLog("Successfully started Realm db for FileProviderExt")
        } catch let error as NSError {
            NSLog("Error opening Realm db: %@", error.localizedDescription)
        }

        super.init()
    }

    private func ncDatabase() -> Realm {
        let realm = try! Realm()
        realm.refresh()
        return realm
    }

    func anyItemMetadatasForAccount(_ account: String) -> Bool {
        return !ncDatabase().objects(NextcloudItemMetadataTable.self).filter("account == %@", account).isEmpty
    }

    func itemMetadataFromOcId(_ ocId: String) -> NextcloudItemMetadataTable? {
        // Realm objects are live-fire, i.e. they will be changed and invalidated according to changes in the db
        // Let's therefore create a copy
        if let itemMetadata = ncDatabase().objects(NextcloudItemMetadataTable.self).filter("ocId == %@", ocId).first {
            return NextcloudItemMetadataTable(value: itemMetadata)
        }

        return nil
    }

    private func sortedItemMetadatas(_ metadatas: Results<NextcloudItemMetadataTable>) -> [NextcloudItemMetadataTable] {
        let sortedMetadatas = metadatas.sorted(byKeyPath: "fileName", ascending: true)
        return Array(sortedMetadatas.map { NextcloudItemMetadataTable(value: $0) })
    }

    func itemMetadatas(account: String, serverUrl: String) -> [NextcloudItemMetadataTable] {
        let metadatas = ncDatabase().objects(NextcloudItemMetadataTable.self).filter("account == %@ AND serverUrl == %@", account, serverUrl)
        return sortedItemMetadatas(metadatas)
    }

    func itemMetadatas(account: String, serverUrl: String, status: NextcloudItemMetadataTable.Status) -> [NextcloudItemMetadataTable] {
        let metadatas = ncDatabase().objects(NextcloudItemMetadataTable.self).filter("account == %@ AND serverUrl == %@ AND status == %@", account, serverUrl, status.rawValue)
        return sortedItemMetadatas(metadatas)
    }

    func itemMetadataFromFileProviderItemIdentifier(_ identifier: NSFileProviderItemIdentifier) -> NextcloudItemMetadataTable? {
        let ocId = identifier.rawValue
        return itemMetadataFromOcId(ocId)
    }

    private func processItemMetadatasToDelete(databaseToWriteTo: Realm,
                                              existingMetadatas: [NextcloudItemMetadataTable],
                                              updatedMetadatas: [NextcloudItemMetadataTable]) {

        assert(databaseToWriteTo.isInWriteTransaction)

        for existingMetadata in existingMetadatas {
            guard !updatedMetadatas.contains(where: { $0.ocId == existingMetadata.ocId }),
                    let metadataToDelete = itemMetadataFromOcId(existingMetadata.ocId) else { continue }

            NSLog("""
                    Deleting metadata.
                    ocID: %@,
                    fileName: %@,
                    etag: %@
                  """
                  , metadataToDelete.ocId, metadataToDelete.fileName, metadataToDelete.etag)
            databaseToWriteTo.delete(metadataToDelete)
        }
    }

    private func processItemMetadatasToUpdate(databaseToWriteTo: Realm,
                                              existingMetadatas: [NextcloudItemMetadataTable],
                                              updatedMetadatas: [NextcloudItemMetadataTable]) {

        assert(databaseToWriteTo.isInWriteTransaction)

        for updatedMetadata in updatedMetadatas {
            if let existingMetadata = existingMetadatas.first(where: { $0.ocId == updatedMetadata.ocId }) {

                if existingMetadata.status == NextcloudItemMetadataTable.Status.normal.rawValue &&
                    !existingMetadata.isInSameRemoteState(updatedMetadata) {

                    databaseToWriteTo.add(NextcloudItemMetadataTable(value: updatedMetadata), update: .all)
                    NSLog("""
                            Updated existing metadata.
                            ocID: %@,
                            fileName: %@,
                            etag: %@
                          """
                          , updatedMetadata.ocId, updatedMetadata.fileName, updatedMetadata.etag)
                }
                // Don't update under other circumstances in which the metadata already exists

            } else { // This is a new metadata
                databaseToWriteTo.add(NextcloudItemMetadataTable(value: updatedMetadata), update: .all)
                NSLog("""
                        Created new metadata.
                        ocID: %@,
                        fileName: %@,
                        etag: %@
                      """
                      , updatedMetadata.ocId, updatedMetadata.fileName, updatedMetadata.etag)
            }
        }
    }

    func updateItemMetadatas(account: String, serverUrl: String, updatedMetadatas: [NextcloudItemMetadataTable]) {
        let database = ncDatabase()

        do {
            try database.write {
                let existingMetadatas = itemMetadatas(account: account, serverUrl: serverUrl, status: .normal)
                processItemMetadatasToDelete(databaseToWriteTo: database,
                                             existingMetadatas: existingMetadatas,
                                             updatedMetadatas: updatedMetadatas)


                processItemMetadatasToUpdate(databaseToWriteTo: database,
                                             existingMetadatas: existingMetadatas,
                                             updatedMetadatas: updatedMetadatas)
            }
        } catch let error {
            NSLog("Could not update any metadatas, received error: %@", error.localizedDescription)
        }
    }

    func directoryMetadata(account: String, serverUrl: String) -> NextcloudDirectoryMetadataTable? {
        if let metadata = ncDatabase().objects(NextcloudDirectoryMetadataTable.self).filter("account == %@ AND serverUrl == %@", account, serverUrl).first {
            return NextcloudDirectoryMetadataTable(value: metadata)
        }

        return nil
    }

    func directoryMetadata(ocId: String) -> NextcloudDirectoryMetadataTable? {
        if let metadata = ncDatabase().objects(NextcloudDirectoryMetadataTable.self).filter("ocId == %@", ocId).first {
            return NextcloudDirectoryMetadataTable(value: metadata)
        }

        return nil
    }

    func parentDirectoryMetadataForItem(_ itemMetadata: NextcloudItemMetadataTable) -> NextcloudDirectoryMetadataTable? {
        return directoryMetadata(account: itemMetadata.account, serverUrl: itemMetadata.serverUrl)
    }

    func directoryMetadatas(account: String, parentDirectoryServerUrl: String) -> [NextcloudDirectoryMetadataTable] {
        let metadatas = ncDatabase().objects(NextcloudDirectoryMetadataTable.self).filter("account == %@ AND parentDirectoryServerUrl == %@", account, parentDirectoryServerUrl)
        let sortedMetadatas = metadatas.sorted(byKeyPath: "serverUrl", ascending: true)
        return Array(sortedMetadatas.map { NextcloudDirectoryMetadataTable(value: $0) })
    }

    private func processDirectoryMetadatasToDelete(databaseToWriteTo: Realm,
                                           existingDirectoryMetadatas: [NextcloudDirectoryMetadataTable],
                                           updatedDirectoryMetadatas: [NextcloudDirectoryMetadataTable]) {

        assert(databaseToWriteTo.isInWriteTransaction)

        for existingMetadata in existingDirectoryMetadatas {
            guard !updatedDirectoryMetadatas.contains(where: { $0.ocId == existingMetadata.ocId }),
                  let metadataToDelete = directoryMetadata(ocId: existingMetadata.ocId) else { continue }

            NSLog("""
                    Deleting directory metadata.
                    ocID: %@,
                    serverUrl: %@,
                    etag: %@
                  """
                  , metadataToDelete.ocId, metadataToDelete.serverUrl, metadataToDelete.etag)
            databaseToWriteTo.delete(metadataToDelete)
        }
    }

    private func processDirectoryMetadatasToUpdate(databaseToWriteTo: Realm,
                                           existingDirectoryMetadatas: [NextcloudDirectoryMetadataTable],
                                           updatedDirectoryMetadatas: [NextcloudDirectoryMetadataTable]) {

        assert(databaseToWriteTo.isInWriteTransaction)

        for updatedMetadata in updatedDirectoryMetadatas {
            if let existingMetadata = existingDirectoryMetadatas.first(where: { $0.ocId == updatedMetadata.ocId }) {

                if !existingMetadata.isInSameRemoteState(updatedMetadata) {

                    databaseToWriteTo.add(NextcloudDirectoryMetadataTable(value: updatedMetadata), update: .all)
                    NSLog("""
                            Updated existing directory metadata.
                            ocID: %@,
                            serverUrl: %@,
                            etag: %@
                          """
                          , updatedMetadata.ocId, updatedMetadata.serverUrl, updatedMetadata.etag)
                }
                // Don't update under other circumstances in which the metadata already exists

            } else { // This is a new metadata
                databaseToWriteTo.add(NextcloudDirectoryMetadataTable(value: updatedMetadata), update: .all)
                NSLog("""
                        Created new metadata.
                        ocID: %@,
                        serverUrl: %@,
                        etag: %@
                      """
                      , updatedMetadata.ocId, updatedMetadata.serverUrl, updatedMetadata.etag)
            }
        }
    }

    func updateDirectoryMetadatas(account: String, parentDirectoryServerUrl: String, updatedDirectoryMetadatas: [NextcloudDirectoryMetadataTable]) {
        let database = ncDatabase()

        do {
            try database.write {
                let existingDirectoryMetadatas = directoryMetadatas(account: account, parentDirectoryServerUrl: parentDirectoryServerUrl)
                processDirectoryMetadatasToDelete(databaseToWriteTo: database,
                                                  existingDirectoryMetadatas: existingDirectoryMetadatas,
                                                  updatedDirectoryMetadatas: updatedDirectoryMetadatas)

                processDirectoryMetadatasToUpdate(databaseToWriteTo: database,
                                                  existingDirectoryMetadatas: existingDirectoryMetadatas,
                                                  updatedDirectoryMetadatas: updatedDirectoryMetadatas)
            }
        } catch let error {
            NSLog("Could not update directory metadatas, received error: %@", error.localizedDescription)
        }
    }

    private func directoryMetadataFromItemMetadata(directoryItemMetadata: NextcloudItemMetadataTable, recordEtag: Bool = false) -> NextcloudDirectoryMetadataTable {
        var newDirectoryMetadata = NextcloudDirectoryMetadataTable()
        let directoryOcId = directoryItemMetadata.ocId

        if let existingDirectoryMetadata = directoryMetadata(ocId: directoryOcId) {
            newDirectoryMetadata = existingDirectoryMetadata
        }

        if recordEtag {
            newDirectoryMetadata.etag = directoryItemMetadata.etag
        }

        newDirectoryMetadata.ocId = directoryOcId
        newDirectoryMetadata.fileId = directoryItemMetadata.fileId
        newDirectoryMetadata.parentDirectoryServerUrl = directoryItemMetadata.serverUrl
        newDirectoryMetadata.serverUrl = directoryItemMetadata.serverUrl + "/" + directoryItemMetadata.fileNameView
        newDirectoryMetadata.account = directoryItemMetadata.account
        newDirectoryMetadata.e2eEncrypted = directoryItemMetadata.e2eEncrypted
        newDirectoryMetadata.favorite = directoryItemMetadata.favorite
        newDirectoryMetadata.permissions = directoryItemMetadata.permissions

        return newDirectoryMetadata
    }

    func updateDirectoryMetadatasFromItemMetadatas(account: String, parentDirectoryServerUrl: String, updatedDirectoryItemMetadatas: [NextcloudItemMetadataTable], recordEtag: Bool = false) {

        var updatedDirMetadatas: [NextcloudDirectoryMetadataTable] = []

        for directoryItemMetadata in updatedDirectoryItemMetadatas {
            let newDirectoryMetadata = directoryMetadataFromItemMetadata(directoryItemMetadata: directoryItemMetadata, recordEtag: recordEtag)
            updatedDirMetadatas.append(newDirectoryMetadata)
        }

        updateDirectoryMetadatas(account: account, parentDirectoryServerUrl: parentDirectoryServerUrl, updatedDirectoryMetadatas: updatedDirMetadatas)
    }

    func localFileMetadataFromOcId(_ ocId: String) -> NextcloudLocalFileMetadataTable? {
        if let metadata = ncDatabase().objects(NextcloudLocalFileMetadataTable.self).filter("ocId == %@", ocId).first {
            return NextcloudLocalFileMetadataTable(value: metadata)
        }

        return nil
    }

    @objc func convertNKFileToItemMetadata(_ file: NKFile, account: String) -> NextcloudItemMetadataTable {

        let metadata = NextcloudItemMetadataTable()

        metadata.account = account
        metadata.checksums = file.checksums
        metadata.commentsUnread = file.commentsUnread
        metadata.contentType = file.contentType
        if let date = file.creationDate {
            metadata.creationDate = date as Date
        } else {
            metadata.creationDate = file.date as Date
        }
        metadata.dataFingerprint = file.dataFingerprint
        metadata.date = file.date as Date
        metadata.directory = file.directory
        metadata.downloadURL = file.downloadURL
        metadata.e2eEncrypted = file.e2eEncrypted
        metadata.etag = file.etag
        metadata.favorite = file.favorite
        metadata.fileId = file.fileId
        metadata.fileName = file.fileName
        metadata.fileNameView = file.fileName
        metadata.hasPreview = file.hasPreview
        metadata.iconName = file.iconName
        metadata.mountType = file.mountType
        metadata.name = file.name
        metadata.note = file.note
        metadata.ocId = file.ocId
        metadata.ownerId = file.ownerId
        metadata.ownerDisplayName = file.ownerDisplayName
        metadata.lock = file.lock
        metadata.lockOwner = file.lockOwner
        metadata.lockOwnerEditor = file.lockOwnerEditor
        metadata.lockOwnerType = file.lockOwnerType
        metadata.lockOwnerDisplayName = file.lockOwnerDisplayName
        metadata.lockTime = file.lockTime
        metadata.lockTimeOut = file.lockTimeOut
        metadata.path = file.path
        metadata.permissions = file.permissions
        metadata.quotaUsedBytes = file.quotaUsedBytes
        metadata.quotaAvailableBytes = file.quotaAvailableBytes
        metadata.richWorkspace = file.richWorkspace
        metadata.resourceType = file.resourceType
        metadata.serverUrl = file.serverUrl
        metadata.sharePermissionsCollaborationServices = file.sharePermissionsCollaborationServices
        for element in file.sharePermissionsCloudMesh {
            metadata.sharePermissionsCloudMesh.append(element)
        }
        for element in file.shareType {
            metadata.shareType.append(element)
        }
        metadata.size = file.size
        metadata.classFile = file.classFile
        //FIXME: iOS 12.0,* don't detect UTI text/markdown, text/x-markdown
        if (metadata.contentType == "text/markdown" || metadata.contentType == "text/x-markdown") && metadata.classFile == NKCommon.typeClassFile.unknow.rawValue {
            metadata.classFile = NKCommon.typeClassFile.document.rawValue
        }
        if let date = file.uploadDate {
            metadata.uploadDate = date as Date
        } else {
            metadata.uploadDate = file.date as Date
        }
        metadata.urlBase = file.urlBase
        metadata.user = file.user
        metadata.userId = file.userId

        // Support for finding the correct filename for e2ee files should go here

        return metadata
    }

    func convertNKFilesToItemMetadatas(_ files: [NKFile], account: String, completionHandler: @escaping (_ directoryMetadata: NextcloudItemMetadataTable, _ childDirectoriesMetadatas: [NextcloudItemMetadataTable], _ metadatas: [NextcloudItemMetadataTable]) -> Void) {

        var directoryMetadataSet = false
        var directoryMetadata = NextcloudItemMetadataTable()
        var childDirectoriesMetadatas: [NextcloudItemMetadataTable] = []
        var metadatas: [NextcloudItemMetadataTable] = []

        for file in files {
            let metadata = convertNKFileToItemMetadata(file, account: account)

            if metadatas.isEmpty && !directoryMetadataSet {
                directoryMetadata = metadata;
                directoryMetadataSet = true;
            } else {
                metadatas.append(metadata)
                if metadata.directory {
                    childDirectoriesMetadatas.append(metadata)
                }
            }
        }

        completionHandler(directoryMetadata, childDirectoriesMetadatas, metadatas)
    }
}
