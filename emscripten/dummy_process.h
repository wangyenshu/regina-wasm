#ifndef DUMMY_PROCESS_H
#define DUMMY_PROCESS_H

#include <QObject>

#ifdef Q_OS_WASM
// WebAssembly cannot spawn native processes, so we stub out QProcess
struct DummyProcess : public QObject {
    enum ProcessChannelMode { MergedChannels, SeparateChannels };
    enum ProcessState { Running, NotRunning };
    enum ExitStatus { NormalExit, CrashExit };
    
    void setProcessChannelMode(int) {}
    template<typename T1, typename T2> void start(T1, T2) {}
    bool waitForStarted(int) { return false; }
    ProcessState state() const { return NotRunning; }
    void kill() {}
    long long write(const char*) { return -1; }
    long long readLine(char*, long long) { return -1; }
};

// Force the compiler to use our dummy class instead of the missing Qt class
#define QProcess DummyProcess
#endif

#endif // DUMMY_PROCESS_H