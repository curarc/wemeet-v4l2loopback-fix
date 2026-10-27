/*
 * test_dqbuf.c —— 复现腾讯会议(wemeet)与 v4l2loopback 的黑屏问题
 *
 * 模拟腾讯会议的 V4L2 采集序列:
 *   open → S_FMT(YUYV) → REQBUFS(4, MMAP) → QUERYBUF/mmap → QBUF×4 → STREAMON
 * 然后分别用 memory=MMAP 和 memory=0 调用 DQBUF / 重新入队 QBUF。
 *
 * 未打补丁的 v4l2loopback 输出:
 *   DQBUF memory=MMAP : 0                        ← 正常
 *   DQBUF memory=0    : -1 EINVAL                ← 腾讯会议黑屏的根源
 *   QBUF requeue memory=0 : -1 EINVAL
 *
 * 已打补丁的驱动:两者都成功。
 *
 * 用法:OBS 虚拟摄像机保持运行,然后
 *   gcc -o test_dqbuf test_dqbuf.c && ./test_dqbuf /dev/video2
 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>

#define NBUF 4

static void dqbuf_report(const char *tag, struct v4l2_buffer *b, int fd)
{
    /* 非阻塞方式:先 poll 2 秒等帧,避免虚拟摄像机未运行时永远阻塞 */
    struct pollfd pfd = { fd, POLLIN, 0 };
    int pr = poll(&pfd, 1, 2000);
    if (pr == 0) {
        printf("%s: 超时无帧(虚拟摄像机是否在运行?)\n", tag);
        return;
    }
    errno = 0;
    int r = ioctl(fd, VIDIOC_DQBUF, b);
    printf("%-24s: %d (%s)\n", tag, r, r ? strerror(errno) : "OK");
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *dev = argc > 1 ? argv[1] : "/dev/video2";
    int fd = open(dev, O_RDWR | O_NONBLOCK);
    if (fd < 0) { perror("open"); return 1; }
    printf("open(%s)           : OK\n", dev);

    int rc;
    struct v4l2_format fmt = {0};
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = 1280;
    fmt.fmt.pix.height = 720;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    errno = 0; rc = ioctl(fd, VIDIOC_S_FMT, &fmt);
    printf("S_FMT  (YUYV)      : %d (%s)\n", rc, rc ? strerror(errno) : "OK");
    if (rc) {
        fprintf(stderr, "\nS_FMT 失败(%s)。exclusive_caps 模式下,若没有写端\n"
                "正在推流(即 OBS 中未点击「启动虚拟摄像机」),设备只通告 OUTPUT。\n"
                "请先在 OBS 中启动虚拟摄像机,再运行本工具。\n", strerror(errno));
        return 1;
    }

    struct v4l2_requestbuffers rb = {0};
    rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    rb.memory = V4L2_MEMORY_MMAP;
    rb.count = NBUF;
    errno = 0; rc = ioctl(fd, VIDIOC_REQBUFS, &rb);
    printf("REQBUFS(%d, MMAP)  : %d (driver gave %d) (%s)\n", NBUF, rc, rb.count,
           rc ? strerror(errno) : "OK");
    if (rc) { perror("REQBUFS"); return 1; }

    void *maps[NBUF] = {0};
    for (int i = 0; i < NBUF; i++) {
        struct v4l2_buffer b = {0};
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = i;
        if (ioctl(fd, VIDIOC_QUERYBUF, &b) < 0) { perror("QUERYBUF"); return 1; }
        maps[i] = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
        if (maps[i] == MAP_FAILED) { perror("mmap"); return 1; }
    }
    for (int i = 0; i < NBUF; i++) {
        struct v4l2_buffer b = {0};
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = i;
        errno = 0; rc = ioctl(fd, VIDIOC_QBUF, &b);
        printf("QBUF(%d) proper    : %d (%s)\n", i, rc, rc ? strerror(errno) : "OK");
        if (rc) return 1;
    }
    int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    errno = 0; rc = ioctl(fd, VIDIOC_STREAMON, &type);
    printf("STREAMON           : %d (%s)\n", rc, rc ? strerror(errno) : "OK");
    if (rc) { perror("STREAMON"); return 1; }

    /* A: 字段规范齐全的 DQBUF(VLC 等应用的做法) */
    struct v4l2_buffer b1 = {0};
    b1.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    b1.memory = V4L2_MEMORY_MMAP;
    dqbuf_report("DQBUF memory=MMAP", &b1, fd);

    /* B: 不设置 memory 字段(腾讯会议的做法) */
    struct v4l2_buffer b2 = {0};
    b2.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    /* b2.memory = 0 —— 故意不设置 */
    dqbuf_report("DQBUF memory=0(wemeet)", &b2, fd);

    if (b1.memory == V4L2_MEMORY_MMAP) {
        struct v4l2_buffer b3 = b1; b3.memory = 0;
        struct v4l2_buffer b4 = b1; b4.memory = V4L2_MEMORY_MMAP;
        errno = 0;
        int r3 = ioctl(fd, VIDIOC_QBUF, &b3);
        printf("%-24s: %d (%s)\n", "QBUF requeue mem=0", r3, r3 ? strerror(errno) : "OK");
        errno = 0;
        int r4 = ioctl(fd, VIDIOC_QBUF, &b4);
        printf("%-24s: %d (%s)\n", "QBUF requeue mem=MMAP", r4, r4 ? strerror(errno) : "OK");
    }

    close(fd);
    return 0;
}
