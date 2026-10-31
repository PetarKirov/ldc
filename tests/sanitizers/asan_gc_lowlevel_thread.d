// AddressSanitizer: collections while other threads create and join low-level
// threads. ASan's `pthread_create` interceptor blocks every signal for the
// whole call, and glibc's `pthread_create` takes locks (the thread stack
// cache, the TLS lock) that a joining thread can hold when the GC suspends it;
// unless `createLowLevelThread` keeps collections out, the creating thread
// then never acknowledges the suspend signal and the collection hangs. A hang
// fails the test through the alarm.

// REQUIRES: ASan, RTSupportsSanitizers
// UNSUPPORTED: Windows

// RUN: %ldc -g -fsanitize=address %s -of=%t%exe
// RUN: %t%exe | FileCheck %s

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.memory : GC;
import core.stdc.stdio : printf;
import core.sys.posix.unistd : alarm;
import core.thread : Thread;
import core.thread.osthread : createLowLevelThread, joinLowLevelThread;
import core.time : msecs;

shared bool stop;
shared long created, collections;

void main()
{
    alarm(120);

    Thread[] threads;
    foreach (i; 0 .. 8)
        threads ~= new Thread({
            while (!atomicLoad(stop))
            {
                joinLowLevelThread(createLowLevelThread(() nothrow {}));
                atomicOp!"+="(created, 1);
            }
        }).start();
    threads ~= new Thread({
        while (!atomicLoad(stop))
        {
            GC.collect();
            atomicOp!"+="(collections, 1);
        }
    }).start();

    Thread.sleep(3000.msecs);
    atomicStore(stop, true);
    foreach (t; threads)
        t.join();

    // CHECK: created and collected
    if (atomicLoad(created) > 0 && atomicLoad(collections) > 0)
        printf("created and collected\n");
}
