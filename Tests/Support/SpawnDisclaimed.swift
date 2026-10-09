import Darwin
// Starts a program as its own TCC "responsible process", so permissions are judged by its own code identity
// instead of the shell or app that launched this tool. Usage: spawn-disclaimed <program> [args...]
@_silgen_name("responsibility_spawnattrs_setdisclaim")
func responsibility_spawnattrs_setdisclaim(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32
guard CommandLine.arguments.count >= 2 else { fputs("usage: spawn-disclaimed program [args...]\n", stderr); exit(64) }
var attr: posix_spawnattr_t? = nil
posix_spawnattr_init(&attr)
guard responsibility_spawnattrs_setdisclaim(&attr, 1) == 0 else { fputs("disclaim not available\n", stderr); exit(70) }
let args = Array(CommandLine.arguments.dropFirst())
var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
var pid: pid_t = 0
let status = posix_spawn(&pid, args[0], nil, &attr, argv, environ)
guard status == 0 else { fputs("spawn failed: \(status)\n", stderr); exit(71) }
print("spawned pid \(pid)")
