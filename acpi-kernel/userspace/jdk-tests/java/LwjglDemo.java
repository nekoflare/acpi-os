// F3: exercises every LWJGL 3.3.1 module that Minecraft 1.20.1 loads, with
// the native libraries from the lwjgl* recipes. Run from source:
//   java -Dos.name=Linux -Dorg.lwjgl.librarypath=/usr/lib/lwjgl -cp '/opt/lwjgl/*' LwjglDemo.java <frames>
// Prints "DEMO OK" when every check passed. On the desktop, `lwjgl-demo`
// runs it until the window is closed.
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.nio.ShortBuffer;

import org.lwjgl.Version;
import org.lwjgl.glfw.GLFWErrorCallback;
import org.lwjgl.openal.AL;
import org.lwjgl.openal.ALC;
import org.lwjgl.openal.ALCCapabilities;
import org.lwjgl.opengl.GL;
import org.lwjgl.stb.STBIWriteCallback;
import org.lwjgl.stb.STBImage;
import org.lwjgl.stb.STBImageWrite;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.system.jemalloc.JEmalloc;

import static org.lwjgl.glfw.GLFW.*;
import static org.lwjgl.openal.AL10.*;
import static org.lwjgl.openal.ALC10.*;
import static org.lwjgl.opengl.GL33C.*;
import static org.lwjgl.system.MemoryUtil.NULL;

public class LwjglDemo {
    static long start = System.nanoTime();

    static void check(boolean ok, String what) {
        if (!ok) {
            throw new IllegalStateException("check failed: " + what);
        }
    }

    static void log(String text) {
        System.out.printf("[%6.2f s] %s%n", (System.nanoTime() - start) / 1e9, text);
    }

    public static void main(String[] arguments) throws Exception {
        int frames = arguments.length > 0 ? Integer.parseInt(arguments[0]) : 300;
        log("LWJGL " + Version.getVersion() + " on " + System.getProperty("java.vm.name"));
        jemalloc();
        stb();
        openal();
        graphics(frames);
        Class.forName("org.lwjgl.util.tinyfd.TinyFileDialogs");
        log("tinyfd: liblwjgl_tinyfd loaded");
        log("DEMO OK");
    }

    // jemalloc: allocate, fill and free through the je_ API.
    static void jemalloc() {
        ByteBuffer block = JEmalloc.je_malloc(1 << 20);
        check(block != null, "je_malloc");
        for (int i = 0; i < block.capacity(); i += 4096) {
            block.put(i, (byte) i);
        }
        JEmalloc.je_free(block);
        log("jemalloc: 1 MiB allocated and freed; MemoryUtil allocator is "
            + MemoryUtil.getAllocator().getClass().getSimpleName());
    }

    // stb: encode a PNG through a native callback (a libffi closure), then
    // decode it again and compare the pixels.
    static void stb() {
        int width = 16, height = 16;
        ByteBuffer pixels = MemoryUtil.memAlloc(width * height * 4);
        for (int i = 0; i < pixels.capacity(); i++) {
            pixels.put(i, (byte) (i * 7));
        }
        ByteArrayOutputStream png = new ByteArrayOutputStream();
        STBIWriteCallback callback = STBIWriteCallback.create((context, data, size) -> {
            byte[] chunk = new byte[size];
            STBIWriteCallback.getData(data, size).get(chunk);
            png.write(chunk, 0, size);
        });
        check(STBImageWrite.stbi_write_png_to_func(callback, NULL, width, height, 4, pixels, width * 4),
            "stbi_write_png_to_func");
        callback.free();
        byte[] bytes = png.toByteArray();
        ByteBuffer encoded = MemoryUtil.memAlloc(bytes.length).put(bytes).flip();
        try (MemoryStack stack = MemoryStack.stackPush()) {
            IntBuffer x = stack.mallocInt(1), y = stack.mallocInt(1), channels = stack.mallocInt(1);
            ByteBuffer decoded = STBImage.stbi_load_from_memory(encoded, x, y, channels, 4);
            check(decoded != null, "stbi_load_from_memory: " + STBImage.stbi_failure_reason());
            check(x.get(0) == width && y.get(0) == height, "PNG size");
            for (int i = 0; i < pixels.capacity(); i++) {
                check(decoded.get(i) == pixels.get(i), "PNG pixel " + i);
            }
            STBImage.stbi_image_free(decoded);
        }
        MemoryUtil.memFree(encoded);
        MemoryUtil.memFree(pixels);
        log("stb: " + width + "x" + height + " PNG round trip through " + bytes.length + " bytes");
    }

    // OpenAL Soft on its null device: play a quarter second of a 440 Hz tone
    // and wait for the source to stop.
    static void openal() throws InterruptedException {
        long device = alcOpenDevice((ByteBuffer) null);
        check(device != NULL, "alcOpenDevice");
        ALCCapabilities deviceCapabilities = ALC.createCapabilities(device);
        log("OpenAL device: " + alcGetString(device, ALC_DEVICE_SPECIFIER));
        long context = alcCreateContext(device, (IntBuffer) null);
        check(context != NULL, "alcCreateContext");
        check(alcMakeContextCurrent(context), "alcMakeContextCurrent");
        AL.createCapabilities(deviceCapabilities);
        log("OpenAL: " + alGetString(AL_VERSION) + ", " + alGetString(AL_RENDERER));

        int rate = 22050;
        ShortBuffer tone = MemoryUtil.memAllocShort(rate / 4);
        for (int i = 0; i < tone.capacity(); i++) {
            tone.put(i, (short) (Math.sin(2 * Math.PI * 440 * i / rate) * 12000));
        }
        int buffer = alGenBuffers();
        alBufferData(buffer, AL_FORMAT_MONO16, tone, rate);
        MemoryUtil.memFree(tone);
        int source = alGenSources();
        alSourcei(source, AL_BUFFER, buffer);
        long played = System.nanoTime();
        alSourcePlay(source);
        while (alGetSourcei(source, AL_SOURCE_STATE) == AL_PLAYING) {
            check(System.nanoTime() - played < 10_000_000_000L, "source still playing after 10 s");
            Thread.sleep(10);
        }
        check(alGetError() == AL_NO_ERROR, "AL error");
        log(String.format("OpenAL: 0.25 s tone played in %.2f s", (System.nanoTime() - played) / 1e9));
        alDeleteSources(source);
        alDeleteBuffers(buffer);
        alcMakeContextCurrent(NULL);
        alcDestroyContext(context);
        check(alcCloseDevice(device), "alcCloseDevice");
    }

    static int shader(int type, String source) {
        int shader = glCreateShader(type);
        glShaderSource(shader, source);
        glCompileShader(shader);
        check(glGetShaderi(shader, GL_COMPILE_STATUS) == GL_TRUE, "shader: " + glGetShaderInfoLog(shader));
        return shader;
    }

    // GLFW window with an OpenGL 3.2 core context, the profile Minecraft
    // asks for, drawing a spinning triangle.
    static void graphics(int frames) {
        GLFWErrorCallback errors = GLFWErrorCallback.createPrint(System.err).set();
        check(glfwInit(), "glfwInit");
        log("GLFW " + glfwGetVersionString());
        glfwDefaultWindowHints();
        glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
        glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 2);
        glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
        glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GLFW_TRUE);
        long window = glfwCreateWindow(320, 240, "LWJGL demo", NULL, NULL);
        check(window != NULL, "glfwCreateWindow");
        int[] events = {0};
        glfwSetKeyCallback(window, (w, key, scancode, action, mods) -> events[0]++);
        glfwSetCursorPosCallback(window, (w, x, y) -> events[0]++);
        glfwMakeContextCurrent(window);
        glfwSwapInterval(0);
        GL.createCapabilities();
        log("OpenGL: " + glGetString(GL_VERSION) + " on " + glGetString(GL_RENDERER));
        try (MemoryStack stack = MemoryStack.stackPush()) {
            IntBuffer width = stack.mallocInt(1), height = stack.mallocInt(1);
            glfwGetFramebufferSize(window, width, height);
            log("GLFW window: framebuffer " + width.get(0) + "x" + height.get(0)
                + ", monitor " + glfwGetMonitorName(glfwGetPrimaryMonitor()));
        }

        int program = glCreateProgram();
        glAttachShader(program, shader(GL_VERTEX_SHADER,
            "#version 150 core\n"
            + "in vec2 position; in vec3 color; out vec3 shade; uniform float angle;\n"
            + "void main() {\n"
            + "  mat2 r = mat2(cos(angle), sin(angle), -sin(angle), cos(angle));\n"
            + "  gl_Position = vec4(r * position, 0.0, 1.0); shade = color;\n"
            + "}\n"));
        glAttachShader(program, shader(GL_FRAGMENT_SHADER,
            "#version 150 core\n"
            + "in vec3 shade; out vec4 fragment;\n"
            + "void main() { fragment = vec4(shade, 1.0); }\n"));
        glBindAttribLocation(program, 0, "position");
        glBindAttribLocation(program, 1, "color");
        glLinkProgram(program);
        check(glGetProgrami(program, GL_LINK_STATUS) == GL_TRUE, "link: " + glGetProgramInfoLog(program));
        glUseProgram(program);
        int angle = glGetUniformLocation(program, "angle");

        int vao = glGenVertexArrays();
        glBindVertexArray(vao);
        int vbo = glGenBuffers();
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        try (MemoryStack stack = MemoryStack.stackPush()) {
            FloatBuffer vertices = stack.floats(
                0.0f, 0.8f, 1f, 0f, 0f,
                -0.7f, -0.4f, 0f, 1f, 0f,
                0.7f, -0.4f, 0f, 0f, 1f);
            glBufferData(GL_ARRAY_BUFFER, vertices, GL_STATIC_DRAW);
        }
        glVertexAttribPointer(0, 2, GL_FLOAT, false, 20, 0);
        glVertexAttribPointer(1, 3, GL_FLOAT, false, 20, 8);
        glEnableVertexAttribArray(0);
        glEnableVertexAttribArray(1);

        long began = System.nanoTime(), report = began;
        int reported = 0, drawn = 0;
        for (int frame = 0; frame < frames && !glfwWindowShouldClose(window); frame++) {
            glViewport(0, 0, 320, 240);
            glClearColor(0.1f, 0.1f, 0.3f, 1f);
            glClear(GL_COLOR_BUFFER_BIT);
            glUniform1f(angle, frame * 0.05f);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            if (frame == 0) {
                try (MemoryStack stack = MemoryStack.stackPush()) {
                    ByteBuffer pixel = stack.malloc(4);
                    glReadPixels(2, 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
                    int corner = pixel.getInt(0);
                    check(Math.abs((pixel.get(0) & 0xff) - 26) <= 1 && Math.abs((pixel.get(2) & 0xff) - 77) <= 1,
                        String.format("corner pixel %08x is not the clear color", corner));
                    glReadPixels(160, 120, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
                    check(pixel.getInt(0) != corner, "triangle missing at the centre");
                    log(String.format("first frame: corner %08x, centre %08x", corner, pixel.getInt(0)));
                }
                check(glGetError() == GL_NO_ERROR, "GL error");
            }
            glfwSwapBuffers(window);
            glfwPollEvents();
            if (System.nanoTime() - report >= 5_000_000_000L) {
                log(String.format("%d frames in 5 s (%.1f fps)", frame + 1 - reported,
                    (frame + 1 - reported) / ((System.nanoTime() - report) / 1e9)));
                report = System.nanoTime();
                reported = frame + 1;
            }
            drawn = frame + 1;
        }
        double seconds = (System.nanoTime() - began) / 1e9;
        log(String.format("%d frames in %.2f s (%.1f fps), %d input events", drawn, seconds,
            drawn / seconds, events[0]));

        glDeleteBuffers(vbo);
        glDeleteVertexArrays(vao);
        glDeleteProgram(program);
        GL.setCapabilities(null);
        glfwDestroyWindow(window);
        glfwTerminate();
        errors.free();
    }
}
