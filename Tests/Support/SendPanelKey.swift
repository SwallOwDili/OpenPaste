import AppKit
import ApplicationServices
guard let key = CommandLine.arguments.dropFirst().first else { print("Usage: SendPanelKey return|shift-return|escape|right|left|command-1"); exit(1) }
let entries: [String:(CGKeyCode,CGEventFlags)] = ["return":(36,[]),"shift-return":(36,[.maskShift]),"escape":(53,[]),"right":(124,[]),"left":(123,[]),"command-1":(18,[.maskCommand])]
guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "io.github.SwallOwDili.OpenPaste", let (code,flags) = entries[key], CGPreflightPostEventAccess() else { print("BLOCKED: target or permission not ready"); exit(2) }
let source = CGEventSource(stateID:.privateState)!
func post(_ key: CGKeyCode, _ down: Bool, _ modifiers: CGEventFlags) { let event=CGEvent(keyboardEventSource:source,virtualKey:key,keyDown:down)!; event.flags=modifiers;event.post(tap:.cghidEventTap);Thread.sleep(forTimeInterval:0.025) }
let modifier: CGKeyCode? = flags.contains(.maskShift) ? 56 : (flags.contains(.maskCommand) ? 55 : nil)
if let modifier { post(modifier,true,flags) }
post(code,true,flags);post(code,false,flags)
if let modifier { post(modifier,false,[]) }
print("Posted panel key",key)
