#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

#include <avisynth.h>

#ifndef _WIN32
typedef unsigned char BYTE;
#endif

const AVS_Linkage *AVS_linkage = nullptr;

static bool write_plane(const PVideoFrame &frame, int plane, FILE *out) {
    const BYTE *src = frame->GetReadPtr(plane);
    int pitch = frame->GetPitch(plane);
    int row_size = frame->GetRowSize(plane);
    int height = frame->GetHeight(plane);

    for (int y = 0; y < height; y++) {
        if (fwrite(src + (int64_t)y * pitch, 1, row_size, out) != (size_t)row_size) {
            return false;
        }
    }
    return true;
}

int main(int argc, const char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <script.avs>\n", argv[0]);
        return 2;
    }

    void *handle = dlopen("libavisynth.so", RTLD_LAZY);
    if (!handle) {
        fprintf(stderr, "Cannot open libavisynth.so: %s\n", dlerror());
        return 1;
    }

    void *maker = dlsym(handle, "CreateScriptEnvironment");
    if (!maker) {
        fprintf(stderr, "Cannot find CreateScriptEnvironment\n");
        dlclose(handle);
        return 1;
    }

    typedef IScriptEnvironment *(*CreateScriptEnvironmentFunc)(int);
    IScriptEnvironment *env =
        ((CreateScriptEnvironmentFunc)maker)(AVISYNTH_INTERFACE_VERSION);
    AVS_linkage = env->GetAVSLinkage();

    AVSValue result;
    try {
        result = env->Invoke("Import", AVSValue(argv[1]));
    } catch (const AvisynthError &err) {
        fprintf(stderr, "AviSynth Import failed: %s\n", err.msg);
        dlclose(handle);
        return 1;
    }

    if (!result.IsClip()) {
        fprintf(stderr, "AviSynth script did not return a clip\n");
        dlclose(handle);
        return 1;
    }

    PClip clip = result.AsClip();
    VideoInfo info = clip->GetVideoInfo();
    if (!info.HasVideo()) {
        fprintf(stderr, "AviSynth clip has no video\n");
        dlclose(handle);
        return 1;
    }

    if (info.IsFieldBased()) {
        try {
            result = env->Invoke("Weave", result);
        } catch (const AvisynthError &err) {
            fprintf(stderr, "AviSynth Weave failed: %s\n", err.msg);
            dlclose(handle);
            return 1;
        }
        clip = result.AsClip();
        info = clip->GetVideoInfo();
    }

    if (info.BitsPerPixel() != 12) {
        const char *arg_names[2] = {nullptr, "interlaced"};
        AVSValue args[2] = {result, true};
        try {
            result = env->Invoke("ConvertToYV12", AVSValue(args, 2), arg_names);
        } catch (const AvisynthError &err) {
            fprintf(stderr, "AviSynth ConvertToYV12 failed: %s\n", err.msg);
            dlclose(handle);
            return 1;
        }
        clip = result.AsClip();
        info = clip->GetVideoInfo();
    }

    fprintf(stdout, "YUV4MPEG2 W%d H%d F%u:%u Ip A0:0 C420mpeg2\n",
            info.width, info.height, info.fps_numerator, info.fps_denominator);

    for (int n = 0; n < info.num_frames; n++) {
        PVideoFrame frame;
        try {
            frame = clip->GetFrame(n, env);
        } catch (const AvisynthError &err) {
            fprintf(stderr, "AviSynth frame %d failed: %s\n", n, err.msg);
            dlclose(handle);
            return 1;
        }

        fputs("FRAME\n", stdout);
        if (!write_plane(frame, PLANAR_Y, stdout) ||
            !write_plane(frame, PLANAR_U, stdout) ||
            !write_plane(frame, PLANAR_V, stdout)) {
            fprintf(stderr, "Failed to write frame %d\n", n);
            dlclose(handle);
            return 1;
        }
    }

    dlclose(handle);
    return 0;
}
