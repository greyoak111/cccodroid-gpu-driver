/* clprobe.c — glibc 侧的 OpenCL 自测：枚举平台/设备 + 跑一个向量加 kernel（真编译、真执行）
 *
 * 编译（在本机，用本仓库的 lgpu-cc）：
 *   lgpu-cc lib/clprobe.c -o clprobe -lOpenCL
 * 运行：
 *   lgpu-run ./clprobe
 *
 * 向量加走 clCreateProgramWithSource —— 也就是必须真有一个 OpenCL C 编译器
 * （clvk 内嵌的 clspv）。只想确认能不能加载库，跑到"平台/设备"就够了。
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef void *cl_platform_id;
typedef void *cl_device_id;
typedef void *cl_context;
typedef void *cl_command_queue;
typedef void *cl_program;
typedef void *cl_kernel;
typedef void *cl_mem;
typedef unsigned int cl_uint;
typedef unsigned long cl_ulong;
typedef int cl_int;

#define CL_DEVICE_TYPE_ALL   0xFFFFFFFFu
#define CL_PLATFORM_NAME     0x0902
#define CL_PLATFORM_VERSION  0x0901
#define CL_DEVICE_NAME       0x102B
#define CL_DEVICE_VERSION    0x102F
#define CL_PROGRAM_BUILD_LOG 0x1183
#define CL_MEM_READ_ONLY     (1 << 2)
#define CL_MEM_WRITE_ONLY    (1 << 1)
#define CL_MEM_COPY_HOST_PTR (1 << 5)
#define CL_TRUE 1

typedef cl_int (*clGetPlatformIDs_t)(cl_uint, cl_platform_id *, cl_uint *);
typedef cl_int (*clGetPlatformInfo_t)(cl_platform_id, cl_uint, size_t, void *, size_t *);
typedef cl_int (*clGetDeviceIDs_t)(cl_platform_id, cl_ulong, cl_uint, cl_device_id *, cl_uint *);
typedef cl_int (*clGetDeviceInfo_t)(cl_device_id, cl_uint, size_t, void *, size_t *);
typedef cl_context (*clCreateContext_t)(const void *, cl_uint, const cl_device_id *, void *, void *, cl_int *);
typedef cl_command_queue (*clCreateCommandQueue_t)(cl_context, cl_device_id, cl_ulong, cl_int *);
typedef cl_mem (*clCreateBuffer_t)(cl_context, cl_ulong, size_t, void *, cl_int *);
typedef cl_program (*clCreateProgramWithSource_t)(cl_context, cl_uint, const char **, const size_t *, cl_int *);
typedef cl_int (*clBuildProgram_t)(cl_program, cl_uint, const cl_device_id *, const char *, void *, void *);
typedef cl_int (*clGetProgramBuildInfo_t)(cl_program, cl_device_id, cl_uint, size_t, void *, size_t *);
typedef cl_kernel (*clCreateKernel_t)(cl_program, const char *, cl_int *);
typedef cl_int (*clSetKernelArg_t)(cl_kernel, cl_uint, size_t, const void *);
typedef cl_int (*clEnqueueNDRangeKernel_t)(cl_command_queue, cl_kernel, cl_uint, const size_t *,
                                           const size_t *, const size_t *, cl_uint, const void *, void *);
typedef cl_int (*clEnqueueReadBuffer_t)(cl_command_queue, cl_mem, cl_uint, size_t, size_t,
                                        void *, cl_uint, const void *, void *);
typedef cl_int (*clFinish_t)(cl_command_queue);

#define LOAD(h, name) \
    name##_t name = (name##_t)dlsym((h), #name); \
    if (!(name)) { fprintf(stderr, "缺符号 %s\n", #name); return 11; }

int main(void) {
    void *h = dlopen("libOpenCL.so", RTLD_NOW);
    if (!h) { printf("dlopen(libOpenCL.so) 失败：%s\n", dlerror()); return 2; }
    printf("dlopen(libOpenCL.so) OK\n");

    LOAD(h, clGetPlatformIDs);
    LOAD(h, clGetPlatformInfo);
    LOAD(h, clGetDeviceIDs);
    LOAD(h, clGetDeviceInfo);
    LOAD(h, clCreateContext);
    LOAD(h, clCreateCommandQueue);
    LOAD(h, clCreateBuffer);
    LOAD(h, clCreateProgramWithSource);
    LOAD(h, clBuildProgram);
    LOAD(h, clGetProgramBuildInfo);
    LOAD(h, clCreateKernel);
    LOAD(h, clSetKernelArg);
    LOAD(h, clEnqueueNDRangeKernel);
    LOAD(h, clEnqueueReadBuffer);
    LOAD(h, clFinish);

    cl_uint np = 0;
    cl_int e = clGetPlatformIDs(0, NULL, &np);
    printf("clGetPlatformIDs -> rc=%d, 平台数=%u\n", e, np);
    if (e != 0 || np == 0) return 3;

    cl_platform_id plats[8];
    clGetPlatformIDs(np > 8 ? 8 : np, plats, NULL);
    char buf[256];
    clGetPlatformInfo(plats[0], CL_PLATFORM_NAME, sizeof buf, buf, NULL);
    printf("  平台: %s\n", buf);
    clGetPlatformInfo(plats[0], CL_PLATFORM_VERSION, sizeof buf, buf, NULL);
    printf("  版本: %s\n", buf);

    cl_uint nd = 0;
    if (clGetDeviceIDs(plats[0], CL_DEVICE_TYPE_ALL, 4, NULL, &nd) != 0 || nd == 0) {
        puts("没有设备");
        return 4;
    }
    cl_device_id devs[4];
    clGetDeviceIDs(plats[0], CL_DEVICE_TYPE_ALL, nd, devs, NULL);
    clGetDeviceInfo(devs[0], CL_DEVICE_NAME, sizeof buf, buf, NULL);
    printf("  设备: %s\n", buf);
    clGetDeviceInfo(devs[0], CL_DEVICE_VERSION, sizeof buf, buf, NULL);
    printf("  版本: %s\n", buf);

    /* ── 向量加 ── */
    cl_int err = 0;
    cl_context ctx = clCreateContext(NULL, 1, devs, NULL, NULL, &err);
    cl_command_queue q = clCreateCommandQueue(ctx, devs[0], 0, &err);
    const int N = 4096;
    float *a = malloc(N * sizeof(float)), *b = malloc(N * sizeof(float)), *out = malloc(N * sizeof(float));
    for (int i = 0; i < N; i++) { a[i] = (float)i; b[i] = (float)(2 * i); }
    cl_mem ma = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, N * sizeof(float), a, &err);
    cl_mem mb = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, N * sizeof(float), b, &err);
    cl_mem mc = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, N * sizeof(float), NULL, &err);
    if (!ctx || !q || !ma || !mb || !mc) { printf("context/buffer 失败 err=%d\n", err); return 5; }

    const char *src =
        "__kernel void vadd(__global const float *a, __global const float *b,"
        " __global float *c, unsigned int n){"
        "  int i = get_global_id(0); if (i < (int)n) c[i] = a[i] + b[i]; }\n";
    cl_program prog = clCreateProgramWithSource(ctx, 1, &src, NULL, &err);
    cl_int berr = clBuildProgram(prog, 1, devs, NULL, NULL, NULL);
    if (berr != 0) {
        char log[4096] = {0};
        clGetProgramBuildInfo(prog, devs[0], CL_PROGRAM_BUILD_LOG, sizeof log - 1, log, NULL);
        printf("kernel 编译失败 rc=%d\n%s\n", berr, log);
        return 6;
    }
    printf("kernel 编译 OK（说明 clspv 在里面干活）\n");

    cl_kernel k = clCreateKernel(prog, "vadd", &err);
    clSetKernelArg(k, 0, sizeof(cl_mem), &ma);
    clSetKernelArg(k, 1, sizeof(cl_mem), &mb);
    clSetKernelArg(k, 2, sizeof(cl_mem), &mc);
    cl_uint nn = N;
    clSetKernelArg(k, 3, sizeof(cl_uint), &nn);
    size_t gws = N;
    clEnqueueNDRangeKernel(q, k, 1, NULL, &gws, NULL, 0, NULL, NULL);
    clEnqueueReadBuffer(q, mc, CL_TRUE, 0, N * sizeof(float), out, 0, NULL, NULL);
    clFinish(q);

    int bad = 0;
    for (int i = 0; i < N; i++) if (out[i] < 3.0 * i - 1e-3 || out[i] > 3.0 * i + 1e-3) bad++;
    printf("向量加: %s（%d/%d 个不对）\n", bad ? "FAIL" : "PASS", bad, N);
    return bad ? 7 : 0;
}
