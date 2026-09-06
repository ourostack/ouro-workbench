import Darwin
import Foundation
import OuroWorkbenchCore

enum RemoteHelperExit: Int32 {
    case success = 0
    case runtimeFailure = 1
    case usage = 64
    case unavailable = 69
    case software = 70
}

func remoteSpawnSupervised(_ request: RemoteProcessRequest) throws -> RemoteSupervisedChild {
    try RemoteSupervisedProcessFactory.spawn(request)
}

func remoteExec(_ request: RemoteProcessRequest) throws -> Never {
    guard request.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: request.executable) else {
        throw RemoteControlError.dependency("required executable is unavailable")
    }
    if let workingDirectory = request.workingDirectory, chdir(workingDirectory) != 0 {
        throw RemoteControlError.dependency("working directory is unavailable")
    }
    let argv = SpawnInOwnGroup.cStrings([request.executable] + request.arguments)
    defer { argv.deallocate() }
    let envp = SpawnInOwnGroup.cStrings(SpawnInOwnGroup.environmentStrings(request.environment))
    defer { envp.deallocate() }
    _ = Darwin.execve(request.executable, argv.pointers, envp.pointers)
    throw RemoteControlError.dependency("exec failed")
}

func remoteExitStatus(_ status: Int32) -> Never {
    Darwin.exit(status < 0 || status > 255 ? RemoteHelperExit.runtimeFailure.rawValue : status)
}
