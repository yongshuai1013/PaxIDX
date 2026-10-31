// PythonBridge.mm — PaxIDX 內嵌 CPython 預覽橋接
// 把 BeeWare CPython 3.13（Python.framework，CI 內嵌）跑在 PaxIDX 進程內：
// 隔離配置初始化（home＝包內 python/），print 逐行導向 Swift 主控台，
// 每次運行以專案 Sources 目錄為 sys.path[0] 執行 main.py。
// 直譯器只初始化一次（進程級），之後每次運行以 GIL 保護進出。
#import <Foundation/Foundation.h>
#import <Python/Python.h>
#include "NativeToolchainBridge.h"

static int gPyReady = 0;
static paxidx_python_log_fn gLogFn = NULL;
static void *gLogCtx = NULL;

// _paxbridge.emit(line)：Python 端 writer 把整行文字送進來，轉交 Swift 回調
static PyObject *paxbridge_emit(PyObject *self, PyObject *arg) {
    const char *s = PyUnicode_AsUTF8(arg);
    if (s != NULL && gLogFn != NULL) gLogFn(s, gLogCtx);
    Py_RETURN_NONE;
}

static PyMethodDef paxbridge_methods[] = {
    {"emit", paxbridge_emit, METH_O, "emit(line): send one output line to the console"},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef paxbridge_module = {
    PyModuleDef_HEAD_INIT, "_paxbridge", NULL, -1, paxbridge_methods,
};

static PyObject *PyInit__paxbridge(void) {
    return PyModule_Create(&paxbridge_module);
}

// print 導向：逐行緩衝的 writer（stdout 與 stderr 共用，錯誤也進主控台）
static const char *kWriterSetup =
    "import sys, _paxbridge\n"
    "class _PaxWriter:\n"
    "    def __init__(self):\n"
    "        self._buf = ''\n"
    "    def write(self, s):\n"
    "        self._buf += str(s)\n"
    "        while '\\n' in self._buf:\n"
    "            line, self._buf = self._buf.split('\\n', 1)\n"
    "            _paxbridge.emit(line)\n"
    "        return len(s)\n"
    "    def writelines(self, lines):\n"
    "        for _l in lines: self.write(_l)\n"
    "    def flush(self):\n"
    "        if self._buf:\n"
    "            _paxbridge.emit(self._buf)\n"
    "            self._buf = ''\n"
    "    def isatty(self):\n"
    "        return False\n"
    "_pax_writer = _PaxWriter()\n"
    "sys.stdout = _pax_writer\n"
    "sys.stderr = _pax_writer\n";

static int ensurePython(void) {
    if (gPyReady) return 0;
    NSString *home = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"python"];
    NSString *probe = [home stringByAppendingPathComponent:@"lib/python3.13/os.py"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:probe]) return 2;

    PyImport_AppendInittab("_paxbridge", &PyInit__paxbridge);

    PyPreConfig preconfig;
    PyConfig config;
    PyStatus status;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;

    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) return 1;
    wchar_t *whome = Py_DecodeLocale([home UTF8String], NULL);
    status = PyConfig_SetString(&config, &config.home, whome);
    PyMem_RawFree(whome);
    if (PyStatus_Exception(status)) return 1;
    status = PyConfig_Read(&config);
    if (PyStatus_Exception(status)) return 1;
    char *argv[] = {(char *)"paxidx-preview"};
    status = PyConfig_SetBytesArgv(&config, 1, argv);
    if (PyStatus_Exception(status)) return 1;
    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) return 1;

    gPyReady = 1;
    PyEval_SaveThread(); // 釋放 GIL，之後每次運行以 PyGILState 進出
    return 0;
}

int paxidx_python_embedded(void) {
    NSString *probe = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"python/lib/python3.13/os.py"];
    return [[NSFileManager defaultManager] fileExistsAtPath:probe] ? 1 : 0;
}

int paxidx_python_run(const char *scriptDir, paxidx_python_log_fn logFn, void *ctx) {
    int e = ensurePython();
    if (e != 0) return e;
    gLogFn = logFn;
    gLogCtx = ctx;

    PyGILState_STATE gil = PyGILState_Ensure();

    // sys.path[0]＝專案 Sources（同目錄 .py 可互相 import）；先清掉同值舊條目
    PyObject *path = PySys_GetObject("path"); // borrowed
    PyObject *dirObj = PyUnicode_FromString(scriptDir);
    if (path != NULL && dirObj != NULL) {
        for (Py_ssize_t i = PyList_Size(path) - 1; i >= 0; i--) {
            PyObject *item = PyList_GetItem(path, i); // borrowed
            if (item != NULL && PyObject_RichCompareBool(item, dirObj, Py_EQ) == 1) {
                PyList_SetSlice(path, i, i + 1, NULL);
            }
        }
        PyList_Insert(path, 0, dirObj);
    }
    Py_XDECREF(dirObj);

    PyRun_SimpleString(kWriterSetup);

    NSString *mainPath = [[NSString stringWithUTF8String:scriptDir]
        stringByAppendingPathComponent:@"main.py"];
    FILE *f = fopen([mainPath UTF8String], "r");
    int opened = (f != NULL);
    if (opened) {
        int rc = PyRun_SimpleFileEx(f, "main.py", 1);
        if (rc != 0 && PyErr_Occurred()) {
            PyErr_Print(); // SimpleFile 通常已印並清掉，這裡是保險
        }
    }
    // 沖掉 writer 裡最後一行（沒有換行結尾的 print）
    PyObject *out = PySys_GetObject("stdout"); // borrowed
    if (out != NULL) {
        PyObject *r = PyObject_CallMethod(out, "flush", NULL);
        Py_XDECREF(r);
        if (PyErr_Occurred()) PyErr_Clear();
    }

    PyGILState_Release(gil);
    gLogFn = NULL;
    gLogCtx = NULL;
    return opened ? 0 : 3;
}
