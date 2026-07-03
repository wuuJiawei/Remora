enum DockerResourceSelection: Equatable {
    case container(DockerContainer)
    case compose(DockerComposeProject)
    case volume(DockerVolume)
    case image(DockerImage)
    case network(DockerNetwork)
    case activity(DockerContainerStats)
    case placeholder(title: String, subtitle: String)
}
