/****************************************************************************
**
** Copyright (C) 2013 Digia Plc and/or its subsidiary(-ies).
** Contact: http://www.qt-project.org/legal
**
** This file is part of the QtCore module of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL$
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and Digia.  For licensing terms and
** conditions see http://qt.digia.com/licensing.  For further information
** use the contact form at http://qt.digia.com/contact-us.
**
** GNU Lesser General Public License Usage
** Alternatively, this file may be used under the terms of the GNU Lesser
** General Public License version 2.1 as published by the Free Software
** Foundation and appearing in the file LICENSE.LGPL included in the
** packaging of this file.  Please review the following information to
** ensure the GNU Lesser General Public License version 2.1 requirements
** will be met: http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
**
** In addition, as a special exception, Digia gives you certain additional
** rights.  These rights are described in the Digia Qt LGPL Exception
** version 1.1, included in the file LGPL_EXCEPTION.txt in this package.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU
** General Public License version 3.0 as published by the Free Software
** Foundation and appearing in the file LICENSE.GPL included in the
** packaging of this file.  Please review the following information to
** ensure the GNU General Public License version 3.0 requirements will be
** met: http://www.gnu.org/copyleft/gpl.html.
**
**
** $QT_END_LICENSE$
**
****************************************************************************/

#include <qplatformdefs.h>

#include "qdiriterator.h"
#include "qfilesystemwatcher.h"
#include "qfilesystemwatcher_fsevents_p.h"
#include "private/qcore_unix_p.h"
#include "kernel/qcore_mac_p.h"

#ifndef QT_NO_FILESYSTEMWATCHER

#include <qdebug.h>
#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qvarlengtharray.h>

//#define FSEVENT_DEBUG
#ifdef FSEVENT_DEBUG
#  define DEBUG if (true) qDebug
#else
#  define DEBUG if (false) qDebug
#endif

QT_BEGIN_NAMESPACE

static void callBackFunction(ConstFSEventStreamRef streamRef,
                             void *clientCallBackInfo,
                             size_t numEvents,
                             void *eventPaths,
                             const FSEventStreamEventFlags eventFlags[],
                             const FSEventStreamEventId eventIds[])
{
    char **paths = static_cast<char **>(eventPaths);
    QFseventsFileSystemWatcherEngine *engine = static_cast<QFseventsFileSystemWatcherEngine *>(clientCallBackInfo);
    engine->processEvent(streamRef, numEvents, paths, eventFlags, eventIds);
}

void QFseventsFileSystemWatcherEngine::checkDir(DirsByName::iterator &it)
{
    QT_STATBUF st;
    const QString &name = it.key();
    Info &info = it->dirInfo;
    const int res = QT_STAT(QFile::encodeName(name), &st);
    if (res == -1) {
        derefPath(info.watchedPath);
        emit emitDirectoryChanged(info.origPath, true);
        it = watchedDirectories.erase(it);
    } else if (st.st_ctimespec != info.ctime || st.st_mode != info.mode) {
        info.ctime = st.st_ctimespec;
        info.mode = st.st_mode;
        emit emitDirectoryChanged(info.origPath, false);
        ++it;
    } else {
        bool dirChanged = false;
        InfoByName &entries = it->entries;
        // check known entries:
        for (InfoByName::iterator i = entries.begin(); i != entries.end(); ) {
            if (QT_STAT(QFile::encodeName(i.key()), &st) == -1) {
                // entry disappeared
                dirChanged = true;
                i = entries.erase(i);
            } else {
                if (i->ctime != st.st_ctimespec || i->mode != st.st_mode) {
                    // entry changed
                    dirChanged = true;
                    i->ctime = st.st_ctimespec;
                    i->mode = st.st_mode;
                }
                ++i;
            }
        }
        // check for new entries:
        QDirIterator dirIt(name);
        while (dirIt.hasNext()) {
            dirIt.next();
            QString entryName = dirIt.filePath();
            if (!entries.contains(entryName)) {
                dirChanged = true;
                QT_STATBUF st;
                if (QT_STAT(QFile::encodeName(entryName), &st) == -1)
                    continue;
                entries.insert(entryName, Info(QString(), st.st_ctimespec, st.st_mode, QString()));

            }
        }
        if (dirChanged)
            emit emitDirectoryChanged(info.origPath, false);
    }
}

void QFseventsFileSystemWatcherEngine::rescanDirs(const QString &path)
{
    for (DirsByName::iterator it = watchedDirectories.begin(); it != watchedDirectories.end(); ) {
        if (it.key().startsWith(path))
            checkDir(it);
        else
             ++it;
    }
}

void QFseventsFileSystemWatcherEngine::rescanFiles(InfoByName &filesInPath)
{
    for (InfoByName::iterator it = filesInPath.begin(); it != filesInPath.end(); ) {
        QT_STATBUF st;
        QString name = it.key();
        const int res = QT_STAT(QFile::encodeName(name), &st);
        if (res == -1) {
            derefPath(it->watchedPath);
            emit emitFileChanged(it.value().origPath, true);
            it = filesInPath.erase(it);
            continue;
        } else if (st.st_ctimespec != it->ctime || st.st_mode != it->mode) {
            it->ctime = st.st_ctimespec;
            it->mode = st.st_mode;
            emit emitFileChanged(it.value().origPath, false);
        }

        ++it;
    }
}

void QFseventsFileSystemWatcherEngine::rescanFiles(const QString &path)
{
    for (FilesByPath::iterator i = watchedFiles.begin(); i != watchedFiles.end(); ) {
        if (i.key().startsWith(path)) {
            rescanFiles(i.value());
            if (i.value().isEmpty()) {
                i = watchedFiles.erase(i);
                continue;
            }
        }

        ++i;
    }
}

void QFseventsFileSystemWatcherEngine::processEvent(ConstFSEventStreamRef streamRef,
                                                    size_t numEvents,
                                                    char **eventPaths,
                                                    const FSEventStreamEventFlags eventFlags[],
                                                    const FSEventStreamEventId eventIds[])
{
#if defined(Q_OS_OSX) && MAC_OS_X_VERSION_MIN_REQUIRED > MAC_OS_X_VERSION_10_6
    Q_UNUSED(streamRef);

    QMutexLocker locker(&lock);

    for (size_t i = 0; i < numEvents; ++i) {
        FSEventStreamEventFlags eFlags = eventFlags[i];
        DEBUG("Change %llu in %s, flags %x", eventIds[i], eventPaths[i], (unsigned int)eFlags);
        QString path = QFile::decodeName(eventPaths[i]);
        if (path.endsWith(QDir::separator()))
            path = path.mid(0, path.size() - 1);

        if (eFlags & kFSEventStreamEventFlagMustScanSubDirs) {
            DEBUG("\tmust rescan directory because of coalesced events");
            if (eFlags & kFSEventStreamEventFlagUserDropped)
                DEBUG("\t\t... user dropped.");
            if (eFlags & kFSEventStreamEventFlagKernelDropped)
                DEBUG("\t\t... kernel dropped.");
            rescanDirs(path);
            rescanFiles(path);
            continue;
        }

        if (eFlags & kFSEventStreamEventFlagEventIdsWrapped) {
            DEBUG("\tthe event ids wrapped");
            // TODO: verify if we need to do something
        }

        if (eFlags & kFSEventStreamEventFlagRootChanged) {
            // re-check everything:
            DirsByName::iterator dirIt = watchedDirectories.find(path);
            if (dirIt != watchedDirectories.end())
                checkDir(dirIt);
            rescanFiles(path);
            continue;
        }

        if ((eFlags & kFSEventStreamEventFlagItemIsDir) && (eFlags & kFSEventStreamEventFlagItemRemoved))
            rescanDirs(path);

        // check watched directories:
        DirsByName::iterator dirIt = watchedDirectories.find(path);
        if (dirIt != watchedDirectories.end())
            checkDir(dirIt);

        // check watched files:
        FilesByPath::iterator pIt = watchedFiles.find(path);
        if (pIt != watchedFiles.end())
            rescanFiles(pIt.value());
    }
#else
    // This is a work-around for moc: when we put the version check at the top of the header file,
    // moc will still see the Q_OBJECT macro and generate a meta-object when compiling for 10.6,
    // which obviously won't link.
    //
    // So the trick is to still compile this class on 10.6, but never instantiate it.

    Q_UNUSED(streamRef);
    Q_UNUSED(numEvents);
    Q_UNUSED(eventPaths);
    Q_UNUSED(eventFlags);
    Q_UNUSED(eventIds);
#endif
}

void QFseventsFileSystemWatcherEngine::doEmitFileChanged(const QString path, bool removed)
{
    emit fileChanged(path, removed);
}

void QFseventsFileSystemWatcherEngine::doEmitDirectoryChanged(const QString path, bool removed)
{
    emit directoryChanged(path, removed);
}

QFseventsFileSystemWatcherEngine *QFseventsFileSystemWatcherEngine::create(QObject *parent)
{
    return new QFseventsFileSystemWatcherEngine(parent);
}

QFseventsFileSystemWatcherEngine::QFseventsFileSystemWatcherEngine(QObject *parent)
    : QFileSystemWatcherEngine(parent)
    , stream(0)
{

    // We cannot use signal-to-signal queued connections, because the
    // QSignalSpy cannot spot signals fired from other/alien threads.
    connect(this, SIGNAL(emitDirectoryChanged(const QString, bool)),
            this, SLOT(doEmitDirectoryChanged(const QString, bool)), Qt::QueuedConnection);
    connect(this, SIGNAL(emitFileChanged(const QString, bool)),
            this, SLOT(doEmitFileChanged(const QString, bool)), Qt::QueuedConnection);

    queue = dispatch_queue_create("org.qt-project.QFseventsFileSystemWatcherEngine", NULL);
}

QFseventsFileSystemWatcherEngine::~QFseventsFileSystemWatcherEngine()
{
    if (stream)
        FSEventStreamStop(stream);

    // The assumption with the locking strategy is that this class cannot and will not be subclassed!
    QMutexLocker locker(&lock);

    stopStream();
    dispatch_release(queue);
}

QStringList QFseventsFileSystemWatcherEngine::addPaths(const QStringList &paths,
                                                       QStringList *files,
                                                       QStringList *directories)
{
    if (stream)
        FSEventStreamFlushSync(stream);

    QMutexLocker locker(&lock);

    bool newWatchPathsFound = false;

    QStringList p = paths;
    QMutableListIterator<QString> it(p);
    while (it.hasNext()) {
        QString origPath = it.next();
        QString realPath = origPath;
        if (realPath.endsWith(QDir::separator()))
            realPath = realPath.mid(0, realPath.size() - 1);
        QString watchedPath, parentPath;

        realPath = QFileInfo(realPath).canonicalFilePath();
        QFileInfo fi(realPath);
        if (realPath.isEmpty())
            continue;

        QT_STATBUF st;
        if (QT_STAT(QFile::encodeName(realPath), &st) == -1)
            continue;

        const bool isDir = S_ISDIR(st.st_mode);
        if (isDir) {
            if (watchedDirectories.contains(realPath))
                continue;
            directories->append(origPath);
            watchedPath = realPath;
            it.remove();
        } else {
            if (files->contains(origPath))
                continue;
            files->append(origPath);
            it.remove();

            watchedPath = fi.path();
            parentPath = watchedPath;
        }

        for (PathRefCounts::const_iterator i = watchedPaths.begin(), ei = watchedPaths.end(); i != ei; ++i) {
            if (watchedPath.startsWith(i.key())) {
                watchedPath = i.key();
                break;
            }
        }

        PathRefCounts::iterator it = watchedPaths.find(watchedPath);
        if (it == watchedPaths.end()) {
            newWatchPathsFound = true;
            watchedPaths.insert(watchedPath, 1);
        } else {
            ++it.value();
        }

        Info info(origPath, st.st_ctimespec, st.st_mode, watchedPath);
        if (isDir) {
            DirInfo dirInfo;
            dirInfo.dirInfo = info;
            dirInfo.entries = scanForDirEntries(realPath);
            watchedDirectories.insert(realPath, dirInfo);
        } else {
            watchedFiles[parentPath].insert(realPath, info);
        }
    }

    if (newWatchPathsFound) {
        stopStream();
        if (!startStream())
            p = paths;
    }

    return p;
}

QStringList QFseventsFileSystemWatcherEngine::removePaths(const QStringList &paths,
                                                          QStringList *files,
                                                          QStringList *directories)
{
    QMutexLocker locker(&lock);

    QStringList p = paths;
    QMutableListIterator<QString> it(p);
    while (it.hasNext()) {
        QString origPath = it.next();
        QString realPath = origPath;
        if (realPath.endsWith(QDir::separator()))
            realPath = realPath.mid(0, realPath.size() - 1);

        QFileInfo fi(realPath);
        realPath = fi.canonicalFilePath();

        if (fi.isDir()) {
            DirsByName::iterator dirIt = watchedDirectories.find(realPath);
            if (dirIt != watchedDirectories.end()) {
                derefPath(dirIt->dirInfo.watchedPath);
                watchedDirectories.erase(dirIt);
                directories->removeAll(origPath);
                it.remove();
            }
        } else {
            QFileInfo fi(realPath);
            QString parentPath = fi.path();
            FilesByPath::iterator pIt = watchedFiles.find(parentPath);
            if (pIt != watchedFiles.end()) {
                InfoByName &filesInDir = pIt.value();
                InfoByName::iterator fIt = filesInDir.find(realPath);
                if (fIt != filesInDir.end()) {
                    derefPath(fIt->watchedPath);
                    filesInDir.erase(fIt);
                    if (filesInDir.isEmpty())
                        watchedFiles.erase(pIt);
                    files->removeAll(origPath);
                    it.remove();
                }
            }
        }
    }

    return p;
}

bool QFseventsFileSystemWatcherEngine::startStream()
{
    if (watchedPaths.isEmpty())
        return false;

    DEBUG() << "Starting stream with paths" << watchedPaths.keys();

    NSMutableArray *pathsToWatch = [NSMutableArray arrayWithCapacity:watchedPaths.size()];
    for (PathRefCounts::const_iterator i = watchedPaths.begin(), ei = watchedPaths.end(); i != ei; ++i)
        [pathsToWatch addObject:reinterpret_cast<const NSString *>(QCFString::toCFStringRef(i.key()))];

    struct FSEventStreamContext callBackInfo = {
        0,
        this,
        NULL,
        NULL,
        NULL
    };
    const CFAbsoluteTime latency = .5; // in seconds
    FSEventStreamCreateFlags flags = kFSEventStreamCreateFlagWatchRoot;

    stream = FSEventStreamCreate(NULL,
                                 &callBackFunction,
                                 &callBackInfo,
                                 reinterpret_cast<CFArrayRef>(pathsToWatch),
                                 kFSEventStreamEventIdSinceNow,
                                 latency,
                                 flags);

    if (!stream) {
        DEBUG() << "Failed to create stream!";
        return false;
    }

    FSEventStreamSetDispatchQueue(stream, queue);

    if (FSEventStreamStart(stream)) {
        DEBUG() << "Stream started successfully.";
        return true;
    } else {
        DEBUG() << "Stream failed to start!";
        return false;
    }
}

void QFseventsFileSystemWatcherEngine::stopStream(bool isStopped)
{
    if (stream) {
        if (!isStopped)
            FSEventStreamStop(stream);
        FSEventStreamInvalidate(stream);
        FSEventStreamRelease(stream);
        stream = 0;
        DEBUG() << "Stream stopped.";
    }
}

QFseventsFileSystemWatcherEngine::InfoByName QFseventsFileSystemWatcherEngine::scanForDirEntries(const QString &path)
{
    InfoByName entries;

    QDirIterator it(path);
    while (it.hasNext()) {
        it.next();
        QString entryName = it.filePath();
        QT_STATBUF st;
        if (QT_STAT(QFile::encodeName(entryName), &st) == -1)
            continue;
        entries.insert(entryName, Info(QString(), st.st_ctimespec, st.st_mode, QString()));
    }

    return entries;
}

void QFseventsFileSystemWatcherEngine::derefPath(const QString &watchedPath)
{
    PathRefCounts::iterator it = watchedPaths.find(watchedPath);
    if (it == watchedPaths.end())
        return;
    if (--it.value() < 1) {
        watchedPaths.erase(it);
        stopStream();
        startStream();
    }
}

#endif //QT_NO_FILESYSTEMWATCHER

QT_END_NAMESPACE
