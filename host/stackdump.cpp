// In-process thread stack dumps for hang diagnosis (macOS and iOS), no
// debugger needed. UT2004_STACKDUMP="<seconds>[,<seconds>...]" dumps every
// thread's frame-pointer chain to the host log at those times after start.
#include "host_common.h"

#include <cxxabi.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void print_frame(int i, uint64_t addr)
{
    Dl_info info;
    memset(&info, 0, sizeof info);
    if (addr && dladdr((void *)addr, &info) && info.dli_fname) {
        const char *img = strrchr(info.dli_fname, '/');
        img = img ? img + 1 : info.dli_fname;
        int status = -1;
        char *dem = info.dli_sname ? abi::__cxa_demangle(info.dli_sname, NULL, NULL, &status) : NULL;
        const char *name = dem && status == 0 ? dem : (info.dli_sname ? info.dli_sname : "?");
        unsigned long off = info.dli_saddr ? (unsigned long)(addr - (uint64_t)info.dli_saddr) : 0;
        host_log("    #%-2d %-22s %.160s + %lu", i, img, name, off);
        free(dem);
    } else {
        host_log("    #%-2d 0x%llx", i, (unsigned long long)addr);
    }
}

static void dump_thread(thread_t t, int index)
{
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(t, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) != KERN_SUCCESS)
        return;
    char name[64] = "";
    pthread_t pt = pthread_from_mach_thread_np(t);
    if (pt)
        pthread_getname_np(pt, name, sizeof name);
    uint64_t pc = arm_thread_state64_get_pc(st), lr = arm_thread_state64_get_lr(st);
    uint64_t fp = arm_thread_state64_get_fp(st), sp = arm_thread_state64_get_sp(st);
    host_log("  thread %d '%s' pc=0x%llx sp=0x%llx", index, name, (unsigned long long)pc, (unsigned long long)sp);
    print_frame(0, pc);
    print_frame(1, lr);
    for (int i = 2; i < 48 && fp; i++) {
        uint64_t rec[2];
        vm_size_t got = 0;
        if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof rec, (vm_address_t)rec, &got) != KERN_SUCCESS)
            break;
        uint64_t ret = rec[1] & 0x0000007fffffffffull;
        if (!ret)
            break;
        if (i > 2 || ret != lr)
            print_frame(i, ret);
        if (rec[0] <= fp)
            break;
        fp = rec[0];
    }
}

static void dump_all(void)
{
    thread_act_array_t threads;
    mach_msg_type_number_t n = 0;
    if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS)
        return;
    thread_t self = mach_thread_self();
    host_log("[stackdump] %u threads", n);
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        if (threads[i] == self)
            continue;
        if (thread_suspend(threads[i]) == KERN_SUCCESS) {
            dump_thread(threads[i], (int)i);
            thread_resume(threads[i]);
        }
    }
    for (mach_msg_type_number_t i = 0; i < n; i++)
        mach_port_deallocate(mach_task_self(), threads[i]);
    mach_port_deallocate(mach_task_self(), self);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof(thread_t));
}

static char *g_times;

static void *watchdog(void *arg)
{
    (void)arg;
    pthread_setname_np("ut-stackdump");
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    char *save = NULL;
    for (char *tok = strtok_r(g_times, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
        double at = atof(tok);
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double wait = at - ((now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9);
        if (wait > 0)
            usleep((useconds_t)(wait * 1e6));
        host_log("[stackdump] at %.1fs", at);
        dump_all();
    }
    return NULL;
}

void host_stackdump_start(void)
{
    const char *spec = getenv("UT2004_STACKDUMP");
    if (!spec || !*spec)
        return;
    g_times = strdup(spec);
    pthread_t t;
    pthread_create(&t, NULL, watchdog, NULL);
    pthread_detach(t);
}

// ---- crash report ----------------------------------------------------------
// The engine's own signal handler only says "Crash information will be saved
// to your logfile", and its log file (System/UT2004.log) is buffered and never
// written on a crash. Chain in front of it: write the faulting thread's stack
// to the host log, flush the engine log, then let the engine handle it.
#include <signal.h>
#include <sys/ucontext.h>

typedef void (*flush_log_fn)(void *dev);
static flush_log_fn g_flush_log;
static void **g_glog;
static const int kCrashSignals[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP};
static struct sigaction g_prev[32];
static volatile sig_atomic_t g_in_crash;

void host_flush_engine_log(void)
{
    if (!g_flush_log) {
        g_flush_log = (flush_log_fn)dlsym(RTLD_DEFAULT, "_Z11appFlushLogP13FOutputDevice");
        g_glog = (void **)dlsym(RTLD_DEFAULT, "GLog");
    }
    if (g_flush_log && g_glog && *g_glog)
        g_flush_log(*g_glog);
}

static void crash_handler(int sig, siginfo_t *info, void *uctx)
{
    if (!g_in_crash) {
        g_in_crash = 1;
        const _STRUCT_MCONTEXT64 *mc = ((ucontext_t *)uctx)->uc_mcontext;
        uint64_t pc = arm_thread_state64_get_pc(mc->__ss), lr = arm_thread_state64_get_lr(mc->__ss);
        uint64_t fp = arm_thread_state64_get_fp(mc->__ss);
        char name[64] = "";
        pthread_getname_np(pthread_self(), name, sizeof name);
        host_log("[crash] signal %d (%s) addr %p thread '%s'", sig, strsignal(sig), info ? info->si_addr : NULL, name);
        print_frame(0, pc);
        print_frame(1, lr);
        for (int i = 2; i < 64 && fp; i++) {
            uint64_t rec[2];
            vm_size_t got = 0;
            if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof rec, (vm_address_t)rec, &got) != KERN_SUCCESS)
                break;
            uint64_t ret = rec[1] & 0x0000007fffffffffull;
            if (!ret)
                break;
            if (i > 2 || ret != lr)
                print_frame(i, ret);
            if (rec[0] <= fp)
                break;
            fp = rec[0];
        }
        host_flush_engine_log();
    }
    // hand over to the engine's handler (or the default action)
    const struct sigaction *prev = &g_prev[sig];
    if (prev->sa_flags & SA_SIGINFO) {
        if (prev->sa_sigaction) {
            prev->sa_sigaction(sig, info, uctx);
            return;
        }
    } else if (prev->sa_handler != SIG_DFL && prev->sa_handler != SIG_IGN) {
        prev->sa_handler(sig);
        return;
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

// Called once the engine is up (its own handlers are installed by then).
void host_crash_report_install(void)
{
    static bool done;
    if (done)
        return;
    done = true;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = crash_handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    for (int s : kCrashSignals)
        sigaction(s, &sa, &g_prev[s]);
    host_log("[crash] report handler installed");
}
