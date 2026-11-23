// The GL client of the mesa-glx test. Like LWJGL's GLFW, it loads libX11,
// libXrandr and libGL with dlopen, queries RANDR, creates an OpenGL 3.2 core
// context through GLX_ARB_create_context, draws with a GLSL program and checks
// pixels read back from the framebuffer.
#define _GNU_SOURCE
#include <GL/gl.h>
#include <GL/glext.h>
#include <GL/glx.h>
#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>


// glext.h has no pointer types for GL 1.0 and 1.1 entry points.
typedef const GLubyte *(*get_string_fn)(GLenum);
typedef void (*viewport_fn)(GLint, GLint, GLsizei, GLsizei);
typedef void (*clear_color_fn)(GLfloat, GLfloat, GLfloat, GLfloat);
typedef void (*clear_fn)(GLbitfield);
typedef void (*draw_arrays_fn)(GLenum, GLint, GLsizei);
typedef void (*read_pixels_fn)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
typedef void (*finish_fn)(void);
typedef GLenum (*get_error_fn)(void);

#define SIZE 256

static void *x11, *xrandr, *libgl;

static void *sym(void *library, const char *name)
{
    void *address = dlsym(library, name);
    if (!address) { printf("FAIL dlsym %s: %s\n", name, dlerror()); _exit(1); }
    return address;
}

#define X(name) ((__typeof__(name) *)sym(x11, #name))
#define RR(name) ((__typeof__(name) *)sym(xrandr, #name))
#define GLX(name) ((__typeof__(name) *)sym(libgl, #name))

// Core GL entry points come from glXGetProcAddressARB, as GLFW gets them.
static __GLXextFuncPtr gl_proc(const char *name)
{
    __GLXextFuncPtr address = GLX(glXGetProcAddressARB)((const GLubyte *)name);
    if (!address) { printf("FAIL glXGetProcAddressARB %s\n", name); _exit(1); }
    return address;
}
#define GL(type, name) ((type)gl_proc(#name))

static long long now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000LL + ts.tv_nsec / 1000;
}

static const char *vertex_source =
    "#version 150 core\n"
    "in vec2 position;\n"
    "void main() { gl_Position = vec4(position, 0.0, 1.0); }\n";
static const char *fragment_source =
    "#version 150 core\n"
    "uniform vec4 color;\n"
    "out vec4 result;\n"
    "void main() { result = color; }\n";

int main(void)
{
    const char *libraries[] = {"libX11.so.6", "libXrandr.so.2", "libGL.so.1"};
    void **handles[] = {&x11, &xrandr, &libgl};
    for (int i = 0; i < 3; i++) {
        long long start = now_us();
        *handles[i] = dlopen(libraries[i], RTLD_NOW | RTLD_GLOBAL);
        if (!*handles[i]) { printf("FAIL dlopen %s: %s\n", libraries[i], dlerror()); return 1; }
        printf("dlopen %s in %lld ms\n", libraries[i], (now_us() - start) / 1000);
    }

    Display *display = NULL;
    for (int attempt = 0; attempt < 100 && !display; attempt++) {
        display = X(XOpenDisplay)(":0");
        if (!display) { usleep(100000); }
    }
    if (!display) { printf("FAIL XOpenDisplay\n"); return 1; }
    int screen = DefaultScreen(display);
    Window root = RootWindow(display, screen);

    int event_base, error_base, major, minor;
    if (!RR(XRRQueryExtension)(display, &event_base, &error_base) ||
        !RR(XRRQueryVersion)(display, &major, &minor)) {
        printf("FAIL RANDR missing\n");
        return 1;
    }
    XRRScreenResources *resources = RR(XRRGetScreenResourcesCurrent)(display, root);
    if (!resources || resources->noutput < 1 || resources->nmode < 1) {
        printf("FAIL RANDR screen resources\n");
        return 1;
    }
    XRROutputInfo *output = RR(XRRGetOutputInfo)(display, resources, resources->outputs[0]);
    printf("RANDR %d.%d outputs=%d modes=%d first=%s %ux%u\n", major, minor, resources->noutput,
           resources->nmode, output ? output->name : "?", resources->modes[0].width,
           resources->modes[0].height);

    if (!GLX(glXQueryExtension)(display, &error_base, &event_base) ||
        !GLX(glXQueryVersion)(display, &major, &minor)) {
        printf("FAIL GLX missing\n");
        return 1;
    }
    const char *extensions = GLX(glXQueryExtensionsString)(display, screen);
    printf("GLX %d.%d create_context=%d\n", major, minor,
           strstr(extensions, "GLX_ARB_create_context_profile") != NULL);

    int fb_attributes[] = {
        GLX_X_RENDERABLE, True, GLX_DRAWABLE_TYPE, GLX_WINDOW_BIT, GLX_RENDER_TYPE, GLX_RGBA_BIT,
        GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8, GLX_BLUE_SIZE, 8, GLX_DEPTH_SIZE, 24,
        GLX_DOUBLEBUFFER, True, None,
    };
    int count = 0;
    GLXFBConfig *configs = GLX(glXChooseFBConfig)(display, screen, fb_attributes, &count);
    if (!configs || count < 1) { printf("FAIL glXChooseFBConfig\n"); return 1; }
    XVisualInfo *visual = GLX(glXGetVisualFromFBConfig)(display, configs[0]);
    if (!visual) { printf("FAIL glXGetVisualFromFBConfig\n"); return 1; }
    printf("fbconfigs=%d visual=0x%lx depth=%d\n", count, visual->visualid, visual->depth);

    // The visual can be deeper than the root window (32 against 24), so give
    // a border pixel as GLFW does: the inherited border pixmap would not match.
    XSetWindowAttributes window_attributes = {0};
    window_attributes.border_pixel = 0;
    window_attributes.colormap = X(XCreateColormap)(display, root, visual->visual, AllocNone);
    window_attributes.event_mask = ExposureMask | StructureNotifyMask;
    Window window = X(XCreateWindow)(display, root, 0, 0, SIZE, SIZE, 0, visual->depth, InputOutput,
                                     visual->visual, CWBorderPixel | CWColormap | CWEventMask,
                                     &window_attributes);
    X(XStoreName)(display, window, "mesa-glx");
    X(XMapWindow)(display, window);
    X(XSync)(display, False);

    PFNGLXCREATECONTEXTATTRIBSARBPROC create_context =
        (PFNGLXCREATECONTEXTATTRIBSARBPROC)gl_proc("glXCreateContextAttribsARB");
    int context_attributes[] = {
        GLX_CONTEXT_MAJOR_VERSION_ARB, 3, GLX_CONTEXT_MINOR_VERSION_ARB, 2,
        GLX_CONTEXT_PROFILE_MASK_ARB, GLX_CONTEXT_CORE_PROFILE_BIT_ARB, None,
    };
    long long start = now_us();
    GLXContext context = create_context(display, configs[0], NULL, True, context_attributes);
    if (!context || !GLX(glXMakeCurrent)(display, window, context)) {
        printf("FAIL OpenGL 3.2 core context\n");
        return 1;
    }
    printf("context in %lld ms\n", (now_us() - start) / 1000);

    get_string_fn get_string = GL(get_string_fn, glGetString);
    const char *renderer = (const char *)get_string(GL_RENDERER);
    const char *version = (const char *)get_string(GL_VERSION);
    printf("GL_VENDOR=%s\nGL_RENDERER=%s\nGL_VERSION=%s\nGLSL=%s\n", get_string(GL_VENDOR), renderer,
           version, get_string(GL_SHADING_LANGUAGE_VERSION));
    if (!strstr(renderer, "llvmpipe")) { printf("FAIL renderer is not llvmpipe\n"); return 1; }
    int gl_major = 0, gl_minor = 0;
    if (sscanf(version, "%d.%d", &gl_major, &gl_minor) != 2 || gl_major * 10 + gl_minor < 32) {
        printf("FAIL GL version below 3.2\n");
        return 1;
    }

    PFNGLCREATESHADERPROC create_shader = GL(PFNGLCREATESHADERPROC, glCreateShader);
    PFNGLSHADERSOURCEPROC shader_source = GL(PFNGLSHADERSOURCEPROC, glShaderSource);
    PFNGLCOMPILESHADERPROC compile_shader = GL(PFNGLCOMPILESHADERPROC, glCompileShader);
    PFNGLGETSHADERIVPROC get_shader = GL(PFNGLGETSHADERIVPROC, glGetShaderiv);
    PFNGLGETSHADERINFOLOGPROC shader_log = GL(PFNGLGETSHADERINFOLOGPROC, glGetShaderInfoLog);
    PFNGLCREATEPROGRAMPROC create_program = GL(PFNGLCREATEPROGRAMPROC, glCreateProgram);
    PFNGLATTACHSHADERPROC attach_shader = GL(PFNGLATTACHSHADERPROC, glAttachShader);
    PFNGLBINDATTRIBLOCATIONPROC bind_attribute = GL(PFNGLBINDATTRIBLOCATIONPROC, glBindAttribLocation);
    PFNGLLINKPROGRAMPROC link_program = GL(PFNGLLINKPROGRAMPROC, glLinkProgram);
    PFNGLGETPROGRAMIVPROC get_program = GL(PFNGLGETPROGRAMIVPROC, glGetProgramiv);
    PFNGLUSEPROGRAMPROC use_program = GL(PFNGLUSEPROGRAMPROC, glUseProgram);
    PFNGLGETUNIFORMLOCATIONPROC uniform_location = GL(PFNGLGETUNIFORMLOCATIONPROC, glGetUniformLocation);
    PFNGLUNIFORM4FPROC uniform4f = GL(PFNGLUNIFORM4FPROC, glUniform4f);
    PFNGLGENVERTEXARRAYSPROC gen_vertex_arrays = GL(PFNGLGENVERTEXARRAYSPROC, glGenVertexArrays);
    PFNGLBINDVERTEXARRAYPROC bind_vertex_array = GL(PFNGLBINDVERTEXARRAYPROC, glBindVertexArray);
    PFNGLGENBUFFERSPROC gen_buffers = GL(PFNGLGENBUFFERSPROC, glGenBuffers);
    PFNGLBINDBUFFERPROC bind_buffer = GL(PFNGLBINDBUFFERPROC, glBindBuffer);
    PFNGLBUFFERDATAPROC buffer_data = GL(PFNGLBUFFERDATAPROC, glBufferData);
    PFNGLENABLEVERTEXATTRIBARRAYPROC enable_attribute =
        GL(PFNGLENABLEVERTEXATTRIBARRAYPROC, glEnableVertexAttribArray);
    PFNGLVERTEXATTRIBPOINTERPROC attribute_pointer = GL(PFNGLVERTEXATTRIBPOINTERPROC, glVertexAttribPointer);
    viewport_fn viewport = GL(viewport_fn, glViewport);
    clear_color_fn clear_color = GL(clear_color_fn, glClearColor);
    clear_fn clear = GL(clear_fn, glClear);
    draw_arrays_fn draw_arrays = GL(draw_arrays_fn, glDrawArrays);
    read_pixels_fn read_pixels = GL(read_pixels_fn, glReadPixels);
    finish_fn finish = GL(finish_fn, glFinish);
    get_error_fn get_error = GL(get_error_fn, glGetError);

    start = now_us();
    const char *sources[] = {vertex_source, fragment_source};
    GLenum kinds[] = {GL_VERTEX_SHADER, GL_FRAGMENT_SHADER};
    GLuint program = create_program();
    for (int i = 0; i < 2; i++) {
        GLuint shader = create_shader(kinds[i]);
        shader_source(shader, 1, &sources[i], NULL);
        compile_shader(shader);
        GLint ok = 0;
        get_shader(shader, GL_COMPILE_STATUS, &ok);
        if (!ok) {
            char log[1024];
            shader_log(shader, sizeof log, NULL, log);
            printf("FAIL shader %d: %s\n", i, log);
            return 1;
        }
        attach_shader(program, shader);
    }
    bind_attribute(program, 0, "position");
    link_program(program);
    GLint linked = 0;
    get_program(program, GL_LINK_STATUS, &linked);
    if (!linked) { printf("FAIL program link\n"); return 1; }
    use_program(program);
    GLint color = uniform_location(program, "color");

    // A triangle over the lower-left half of the window.
    static const float triangle[] = {-1, -1, 1, -1, -1, 1};
    GLuint vertex_array, buffer;
    gen_vertex_arrays(1, &vertex_array);
    bind_vertex_array(vertex_array);
    gen_buffers(1, &buffer);
    bind_buffer(GL_ARRAY_BUFFER, buffer);
    buffer_data(GL_ARRAY_BUFFER, sizeof triangle, triangle, GL_STATIC_DRAW);
    enable_attribute(0);
    attribute_pointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
    viewport(0, 0, SIZE, SIZE);

    clear_color(0, 0, 1, 1);
    clear(GL_COLOR_BUFFER_BIT);
    uniform4f(color, 1, 0, 0, 1);
    draw_arrays(GL_TRIANGLES, 0, 3);
    finish();
    printf("first frame (shader compile and draw) in %lld ms\n", (now_us() - start) / 1000);
    unsigned char inside[4], outside[4];
    read_pixels(SIZE / 8, SIZE / 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, inside);
    read_pixels(SIZE - SIZE / 8, SIZE - SIZE / 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, outside);
    printf("pixels inside=%02x%02x%02x outside=%02x%02x%02x\n", inside[0], inside[1], inside[2],
           outside[0], outside[1], outside[2]);
    if (inside[0] != 0xff || inside[1] || inside[2] || outside[0] || outside[1] || outside[2] != 0xff) {
        printf("FAIL pixel colors\n");
        return 1;
    }

    // Present frames with changing colors, as an application would.
    start = now_us();
    int frames = 120;
    for (int frame = 0; frame < frames; frame++) {
        clear_color(0, 0, frame / (float)frames, 1);
        clear(GL_COLOR_BUFFER_BIT);
        uniform4f(color, 1, frame / (float)frames, 0, 1);
        draw_arrays(GL_TRIANGLES, 0, 3);
        GLX(glXSwapBuffers)(display, window);
    }
    finish();
    long long elapsed = now_us() - start;
    printf("%d frames in %lld ms (%lld fps)\n", frames, elapsed / 1000, frames * 1000000LL / elapsed);
    GLenum error = get_error();
    if (error != GL_NO_ERROR) { printf("FAIL glGetError 0x%x\n", error); return 1; }

    GLX(glXMakeCurrent)(display, None, NULL);
    GLX(glXDestroyContext)(display, context);
    X(XDestroyWindow)(display, window);
    X(XCloseDisplay)(display);
    printf("GL OK\n");
    return 0;
}
