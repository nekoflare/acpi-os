#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *command;

static int report(const char *path)
{
    fprintf(stderr, "%s: %s: %s\n", command, path, strerror(errno));
    return 1;
}

static int transfer(int input, const char *source, int output, const char *destination)
{
    char buffer[4096];
    for (;;) {
        ssize_t count = read(input, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
            return count < 0 ? report(source) : 0;

        for (ssize_t offset = 0; offset < count;) {
            ssize_t written = write(output, buffer + offset, count - offset);
            if (written < 0 && errno == EINTR)
                continue;
            if (written <= 0) {
                if (!written)
                    errno = EIO;
                return report(destination);
            }
            offset += written;
        }
    }
}

static int show(const char *path)
{
    if (!strcmp(path, "-"))
        return transfer(STDIN_FILENO, "stdin", STDOUT_FILENO, "stdout");
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return report(path);
    int status = transfer(fd, path, STDOUT_FILENO, "stdout");
    close(fd);
    return status;
}

static int ensure_directory(const char *path)
{
    if (!mkdir(path, 0777))
        return 0;
    if (errno == EEXIST) {
        struct stat info;
        if (!stat(path, &info)) {
            if (S_ISDIR(info.st_mode))
                return 0;
            errno = ENOTDIR;
        }
    }
    return report(path);
}

static int make_directory(char *path, bool parents)
{
    if (!parents)
        return mkdir(path, 0777) < 0 ? report(path) : 0;
    for (char *slash = path; (slash = strchr(slash, '/')); ++slash) {
        if (slash == path || slash[-1] == '/')
            continue;
        *slash = '\0';
        int status = ensure_directory(path);
        *slash = '/';
        if (status)
            return status;
    }
    return ensure_directory(path);
}

static int nondot(const struct dirent *entry)
{
    return strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..");
}

static int remove_path(const char *path, bool recursive, bool force)
{
    if (!unlink(path))
        return 0;
    if (errno == ENOENT && force)
        return 0;
    if (errno != EISDIR || !recursive)
        return report(path);

    struct dirent **entries;
    int count = scandir(path, &entries, nondot, NULL);
    if (count < 0)
        return report(path);
    int status = 0;
    for (int i = 0; i < count; ++i) {
        char *child;
        if (asprintf(&child, "%s/%s", path, entries[i]->d_name) < 0) {
            status |= report(path);
        } else {
            status |= remove_path(child, recursive, force);
            free(child);
        }
        free(entries[i]);
    }
    free(entries);
    if (status)
        return status;
    return rmdir(path) < 0 ? report(path) : 0;
}

static char *destination_path(const char *source, const char *destination)
{
    struct stat info;
    if (stat(destination, &info) || !S_ISDIR(info.st_mode))
        return strdup(destination);
    size_t end = strlen(source);
    while (end && source[end - 1] == '/')
        --end;
    size_t start = end;
    while (start && source[start - 1] != '/')
        --start;
    char *path;
    if (asprintf(&path, "%s/%.*s", destination, (int)(end - start), source + start) < 0)
        return NULL;
    return path;
}

static int copy_file(const char *source, const char *destination)
{
    int input = open(source, O_RDONLY);
    if (input < 0)
        return report(source);
    struct stat source_info, target_info;
    int status = 1;
    if (fstat(input, &source_info) < 0) {
        report(source);
    } else if (S_ISDIR(source_info.st_mode)) {
        errno = EISDIR;
        report(source);
    } else if (!stat(destination, &target_info) &&
               source_info.st_dev == target_info.st_dev &&
               source_info.st_ino == target_info.st_ino) {
        errno = EINVAL;
        report(destination);
    } else {
        int output = open(destination, O_WRONLY | O_CREAT | O_TRUNC, source_info.st_mode & 0777);
        if (output < 0) {
            report(destination);
        } else {
            status = transfer(input, source, output, destination);
            if (close(output) < 0)
                status |= report(destination);
        }
    }
    close(input);
    return status;
}

static int usage(const char *operands)
{
    fprintf(stderr, "usage: %s %s\n", command, operands);
    return 2;
}

int main(int argc, char **argv)
{
    const char *slash = strrchr(argv[0], '/');
    command = slash ? slash + 1 : argv[0];
    bool cat = !strcmp(command, "cat");
    bool mkdir_command = !strcmp(command, "mkdir");
    bool rm = !strcmp(command, "rm");
    bool rmdir_command = !strcmp(command, "rmdir");
    bool cp = !strcmp(command, "cp");
    bool mv = !strcmp(command, "mv");
    bool parents = false, recursive = false, force = false;
    const char *operands = cat ? "[FILE ...]" : mkdir_command ? "[-p] DIRECTORY ..." :
                           rm ? "[-rf] FILE ..." : rmdir_command ? "DIRECTORY ..." :
                           "SOURCE DESTINATION";
    int first = 1;
    for (; first < argc && argv[first][0] == '-' && argv[first][1]; ++first) {
        if (!strcmp(argv[first], "--")) {
            ++first;
            break;
        }
        for (const char *option = argv[first] + 1; *option; ++option) {
            if (mkdir_command && *option == 'p')
                parents = true;
            else if (rm && (*option == 'r' || *option == 'R'))
                recursive = true;
            else if (rm && *option == 'f')
                force = true;
            else
                return usage(operands);
        }
    }

    if (cp || mv) {
        if (argc - first != 2)
            return usage(operands);
        const char *source = argv[first];
        char *destination = destination_path(source, argv[first + 1]);
        if (!destination)
            return report(argv[first + 1]);
        int status = cp ? copy_file(source, destination) :
                     rename(source, destination) < 0 ? report(source) : 0;
        free(destination);
        return status;
    }
    if (first == argc) {
        if (cat)
            return show("-");
        return rm && force ? 0 : usage(operands);
    }

    int status = 0;
    for (int i = first; i < argc; ++i) {
        if (cat)
            status |= show(argv[i]);
        else if (mkdir_command)
            status |= make_directory(argv[i], parents);
        else if (rm)
            status |= remove_path(argv[i], recursive, force);
        else if (rmdir_command)
            status |= rmdir(argv[i]) < 0 ? report(argv[i]) : 0;
        else
            return usage(operands);
    }
    return status;
}
