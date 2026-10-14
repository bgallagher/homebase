import Foundation

/// App-level actions for a standalone container (one started with `docker run`, not Docker Compose), the counterparts of a
/// compose stack's Pull and Delete. Restart, stop and start are the container's own `DockerAction`s.
///
/// Update, Rebuild and Recreate have no counterpart: they recreate the container from its definition, and for a container
/// started with `docker run` there is none to recreate it from (only the original command line had it), so Rackoon refuses
/// them instead of guessing the settings back from `docker inspect`.
public enum StandaloneAction: Sendable, Equatable {
    /// `docker pull <image>`: downloads a newer image. The running container keeps the image it was created from.
    case pullImage
    /// `docker rm -f [-v] <id>`: stops and removes the container; with `volumes`, also its anonymous volumes. Named volumes,
    /// bind-mounted folders and the image are never removed.
    case remove(volumes: Bool)

    static let pullTemplate = "docker pull {image}"
    static let pullCommandID = "docker_pull_image"
    static let removeTemplate = "docker rm -f{volumes} {id}"
    static let removeCommandID = "docker_remove"

    public var timeout: TimeInterval {
        switch self {
        case .pullImage: 900
        case .remove: 60
        }
    }

    /// The image reference a standalone stack's container runs, if `docker pull` can fetch it again: an image name such as
    /// `nginx`, `ghcr.io/org/app:1.2` or `app@sha256:…`. Nil for an image id (an image that lost its tag shows as one) and for
    /// anything with characters no image reference has, since the value comes from the server and goes back into a shell.
    public static func pullableImage(of stack: DockerStack) -> String? {
        guard stack.isStandalone, stack.containers.count == 1, let image = stack.containers.first?.image,
              isImageReference(image) else { return nil }
        return image
    }

    static func isImageReference(_ image: String) -> Bool {
        guard image.count <= 512, let first = image.first, first.isASCII, first.isLetter || first.isNumber,
              !image.hasPrefix("sha256:"),
              image.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-/:@".contains($0)) }) else { return false }
        // A bare image id (12 or 64 hex characters) is not something a registry serves.
        let hex = image.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        return !(hex && (image.count == 12 || image.count == 64))
    }

    /// The exact command, or nil if the stack is not one standalone container or a value is unsafe to send.
    public func command(for stack: DockerStack) -> String? {
        guard stack.isStandalone, stack.containers.count == 1, let container = stack.containers.first else { return nil }
        switch self {
        case .pullImage:
            guard let image = Self.pullableImage(of: stack), let quoted = ShellQuote.quote(image) else { return nil }
            return Template.fill(Self.pullTemplate, ["image": quoted])
        case .remove(let volumes):
            guard DockerSession.isContainerID(container.id) else { return nil }
            return Template.fill(Self.removeTemplate, ["volumes": volumes ? " -v" : "", "id": container.id])
        }
    }

    public func intent(for stack: DockerStack) -> Intent? {
        guard let command = command(for: stack) else { return nil }
        let summary = switch self {
        case .pullImage: "Pull the image of \(stack.name)"
        case .remove(let volumes): "Delete container \(stack.name)" + (volumes ? " and its anonymous volumes" : "")
        }
        return Intent(summary: summary, command: command, risk: .mutate)
    }

    /// Why a compose-only action can't be offered for a standalone container, for the disabled menu item.
    public static let needsComposeReason = "Not available: this container was started with docker run, so there is no compose file to recreate it from"
}
