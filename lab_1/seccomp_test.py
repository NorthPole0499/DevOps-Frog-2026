import os
import seccomp
import errno

f = seccomp.SyscallFilter(defaction=seccomp.ALLOW)

f.add_rule(seccomp.ERRNO(errno.EPERM), "mkdir")
f.add_rule(seccomp.ERRNO(errno.EPERM), "mkdirat")

f.load()

print("Seccomp profile loaded")

os.mkdir("/tmp/seccomp-test")
