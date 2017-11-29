///
///  Locker.swift
///
///  Copyright 2017 Tony Stone
///
///  Licensed under the Apache License, Version 2.0 (the "License");
///  you may not use this file except in compliance with the License.
///  You may obtain a copy of the License at
///
///  http://www.apache.org/licenses/LICENSE-2.0
///
///  Unless required by applicable law or agreed to in writing, software
///  distributed under the License is distributed on an "AS IS" BASIS,
///  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///  See the License for the specific language governing permissions and
///  limitations under the License.
///
///  Created by Tony Stone on 10/8/17.
///
import Foundation

#if os(OSX) || os(iOS) || os(watchOS) || os(tvOS)
    import Darwin
#elseif os(Linux) || os(FreeBSD) || os(PS4) || os(Android)  /* Swift 5 support: || os(Cygwin) || os(Haiku) */
    import Glibc
#endif

///
/// The `Locker` class is an implementation of a high concurrency hierarchical lock manager.
///
public class Locker {

    ///
    /// Result of requesting a lock on an resource.
    ///
    public enum LockResult {
        case granted
        case denied
        case timeout
    }
    
    ///
    /// Initialize `self`
    ///
    public init(accessMatrix: LockMatrix = LockMatrix.defaultMatrix) {
        self.lockTable       = [:]
        self.lockTableMutex  = Mutex(.normal)
        self.accessMatrix    = accessMatrix
    }

    ///
    /// Lock a resource in `mode`.
    ///
    public func lock(_ resource: ResourceID, mode: LockMode, timeout: WaitTime = WaitTime.distantFuture) -> LockResult {
        let request = Lock.Request(mode)

        self.lockTableMutex.lock()

        /// Check for an existing lock entry.
        guard let lock = self.lockTable[resource] else {
            /// If no lock entry, there is no owner so just grant the request.
            let lock = Lock(mode: mode)
            self.lockTable[resource] = lock

            request.status = .granted
            lock.queue.add(request)

            self.lockTableMutex.unlock()
            return .granted
        }
        /// Existing lock

        /// Crab to the lock mutex, do not unlock the lock table until the lock is locked.
        lock.mutex.lock()
        self.lockTableMutex.unlock()

        /// The lock is currently owned, do we own this lock?
        if let existing = lock.queue.find(for: request.requester), existing.status == .granted {

            existing.count += 1 /// Increment the number of locks this owner has

            lock.mutex.unlock()
            return .granted
        }

        /// We don't own the lock currently so if there are no waiters and our lock request mode is compatible, we can grant the lock.
        if !lock.queue.contains(status: .waiting) &&
           self.accessMatrix[lock.mode, request.mode] == .allow {

            /// Upgrade the current lock mode.
            lock.mode = LockMode.max(lock.mode, request.mode)
            request.status = .granted

            lock.queue.add(request)

            lock.mutex.unlock()
            return .granted
        }

        ///
        /// At this point, we need to wait so add to waiter list and wait.
        ///
        lock.queue.add(request)
        request.status = .waiting

        ///
        /// Wait for someone to unlock or a timeout.
        ///
        /// Note: the loop protects against **spurious wakeups** because it is the signaler's responsibility to change the status to something other than waiting.
        ///
        while (request.status == .waiting) {
            if request.wait(on: lock.mutex, timeout: timeout) == .timeout {
                request.status = .timeout
            }
        }
        lock.mutex.unlock()
        
        switch request.status {     /// Translate RequestStatus to LockResult 
        case .granted: return .granted
        case .timeout: return .timeout
        default:       return .denied
        }
    }

    ///
    /// Unlock the resource.
    ///
    @discardableResult
    public func unlock(_ resource: ResourceID) -> Bool {
        let requester = Lock.Requester()

        self.lockTableMutex.lock()

        guard let lock = self.lockTable[resource] else {
            self.lockTableMutex.unlock()
            return false
        }
        
        /// Lock the lock before proceeding.
        lock.mutex.lock()

        if let existing = lock.queue.find(for: requester), existing.status == .granted {
            existing.count -= 1    /// Decrement the count for this owner.

            /// If the owner count is greater than 0, this lock must be maintained.
            if existing.count > 0 {
                
                lock.mutex.unlock()
                self.lockTableMutex.unlock()

                return true     /// Only need to decrement lock and return.
            } else {
                lock.queue.remove(request: existing)
                lock.mode = .NL

                if lock.queue.count == 0 {
                    self.lockTable[resource] = nil      /// No requester and no waiters, deallocate the lock structure and exit.

                    lock.mutex.unlock()
                    self.lockTableMutex.unlock()

                    return true
                }
            }
        }

        /// If there are any waiters, grant the lock to the next one (FIFO order).
        for request in lock.queue {

            if request.status == .granted {

                /// If already granted, we need to realigned (possibly downgrade) the group mode of the current lock.
                lock.mode = LockMode.max(lock.mode, request.mode)

            } else if request.status == .waiting  &&
                     self.accessMatrix[lock.mode, request.mode] == .allow {    /// or if this is a compatible lock with the rest of the lock group.
                
                /// Upgrade the lock mode
                lock.mode      = LockMode.max(lock.mode, request.mode)
                request.status = .granted

                request.signal()   /// Signal the waiter that the request status has changed
            } else {
                ///
                /// When a waiter request is encountered that is incompatible
                /// it must wait and any requests behind it in the queue.
                ///
                /// Simply break and exit.
                ///
                break
            }
        }
        lock.mutex.unlock()
        self.lockTableMutex.unlock()
        return true
    }

    private let lockTableMutex: Mutex          /// Mutually locks the the critical section.
    private var lockTable: [ResourceID: Lock]  /// Lock table containing all active locks.
    private var accessMatrix: LockMatrix       /// Current matrix used to determine access when 2 or more locks exist.
}