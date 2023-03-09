---
vim:set tw=999:
---

## Overview

[`agent-ctl`](https://github.com/kata-containers/kata-containers/tree/main/src/tools/agent-ctl)
is a tool to talk (and control) the Kata Containers
[agent](https://github.com/kata-containers/kata-containers/tree/main/src/agent)
that runs inside the Virtual Machine (VM) and manages the container(s)
that run there.

## What is a traditional Linux container?

A container can be a "traditional" one created by a tool such as
Docker or containerd. Such containers are built using, as a minimum,
the "cgroups" and "namespaces" Linux kernel features.

> **Note:** See `cgroups(7)` and `namespaces(7)` for further details.

## Docker evolution

- Docker was the first container manager of note on Linux.
- Originally, the docker daemon was monolithic: it created containers and managed their lifecycles.
- Design was too simplistic.
- When VM based containers solutions such as
  [Clear Containers](https://github.com/clearcontainers) were created,
  it became necessary to modularise the system.
- The monolithic design was split into two parts:

  - The container manager

    Handles container lifecycle (create, start, stop, kill, monitor, _etc_).

  - The runtime

    Responsible for actually creating the container
    (either a "traditional" container, a VM based one, or some other flavour/variant).

## How is a container defined?

```
+-------------------+      +---------------+      +---------+       +-----------+
| container manager |----> |      ?        |----> | runtime | ----> | container |
+-------------------+      +---------------+      +---------+       +-----------+
```

The container manager needs to tell the runtime precisely _how_ to create a
container.

Docker created the [Open Containers Initiative
(OCI)](https://opencontainers.org) to define and standardise the
container lifecycle and container configuration.

## OCI runtime specification

```
+-------------------+      +---------------+      +---------+       +-----------+
| container manager |----> | OCI config    |----> | runtime | ----> | container |
+-------------------+      | (config.json) |      +---------+       +-----------+
                           +---------------+
```

The OCI defined the [runtime specification](https://github.com/opencontainers/runtime-spec)
which describes precisely how the runtime should create the container:

- The container manager creates a file which must be called `config.json` (JSON format).
- The container manager passes this file to the runtime.
- The runtime reads the file and creates the container based on the JSON description.

- A lot of information is encoded in the configuration file, but
  the most fundamental parts are:

  - The program to run inside the container (called the "workload")
    (encoded as `process.args`).

  - The root filesystem the user requested (encoded as `root.path`).

> **Note:** The runtime specification is often referred to simply as "the spec" in the code.

## OCI bundle

An OCI bundle comprises two artifacts:

- A JSON format configuration file (`config.json`)

- A rootfs (a directory tree of files)

See the [bundle specification](https://github.com/opencontainers/runtime-spec/blob/main/bundle.md) for further details.

> **Note:** An OCI bundle colloquially referred to simple as "a bundle" in the code.

## OCI bundle example

```bash
$ image="quay.io/prometheus/busybox:latest"
$ sudo ctr run --runtime "io.containerd.kata.v2" --rm -t "$image" my-container-name sh
                                                      [1]  [2]    [3]               [4]

Key:

- [1]: enable terminal for interactive shell.
- [2]: The user-requested container image (aka "rootfs image") to use (busybox, ubuntu, _etc_).
- [3]: The name the user has chosen for the container.
- [4]: The user-requested "workload" (command to run in the container).
```

Here's a snippet of the OCI config file for the above command:

```json
"process": {
    "terminal": true,        # [1]
    "consoleSize": {
        "height": 25,
        "width": 80
    },
    "env": [
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "TERM=xterm",
        "foo=bar"            # "ctr run --env 'foo=bar' ..."
    ],
    "cwd": "/root",
    "args": [
        "sh"                 # [4]
    ]
},
"root": {
    "path": "rootfs",        # [2]
        "readonly": true
},
```

## Containerd shim v2 specification


- The original OCI runtime specification required the runtime to be a stand alone binary.

  The container manager would call the runtime binary with various standard arguments and options.

- It worked, but suffered from two problems:

  - Performance: the binary had to be run multiple times to create a single container.

  - State handling: Since the binary was called multiple times for an "atomic" operation like creating a container,
    each runtime had to invent their own state passing / persistence handling techniques.

- The containerd project recognised this and created the
  ["shim v2 specification"](https://github.com/containerd/containerd/tree/main/runtime/v2)
  which solves both problems.

- With "shimv2" the runtime is a long running process (a daemon).

  The container manager sends requests to the runtime "shim" over a socket.

- This is where the strange Kata Containers runtime name comes from:

  ```
  containerd-shim-kata-v2
  \--------/ \--/ \--/ \/
     (a)      (b)  (c) (d)

  Key:

  (a) - container manager.
  (b) - component (shim is the runtime).
  (c) - implementation name for Kata Containers.
  (d) - spec version.
  ```

> **Notes:**
>
> - The trailing "v2" is essential: we can't change it to "v3" as there is no shim v3 spec! ;)
>
> - The Shim v2 specification changes many things but it still uses the OCI bundle from the
>   original OCI runtime specification.

## Kata Containers overview diagram

```
$ image="quay.io/prometheus/busybox:latest"
$ sudo ctr run --runtime "io.containerd.kata.v2" --rm -t "$image" my-container-name sh
                                                         \------/                   \/
                                                            |                       |
                                                  user-requested rootfs        user-requested
                                                      image (r)                 workload (w)

            +---------------+
            | agent-ctl [8] |<--------------------->+
            +---------------+                       |
                                                    |
            +------------------+                    |
            | kata-runtime [9] |<------------------>+
            +------------------+                    |
                                                    |  +-----------------------------------------------------+
            +---------------+                       |  | Kata VM                                             |
            | kata-ctl [10] |<--------------------->+  |                                                     |
            +---------------+                       |  |                        /---- Kata Container ------\ |
                                                    |  |                        | +----------------------+ | |
+--------------------------+                Kata    v  -  +-----------------+   | | workload (w)         | | |
| Kata runtime [1]         |<-------------- VSOCK --+---->| Kata Agent [3]  |<->| +----------------------+ | |
|                          |<---------+     agent      -  +-----------------+   | | container rootfs (r) | | |
+--------------------------+          |     protocol   |  | Kata rootfs [5] |   | +----------------------+ | |
| Container manager [2]    |------+   |      [4]       |  +-----------------+   \--------------------------/ |
+--------------------------+ +----v-------+            +-----------------------------------------------------+
| Host rootfs (R)          | | OCI bundle |            |  Guest kernel [6]                                   |
+--------------------------+ +------------+            +-----------------------------------------------------+
| Host kernel              |                           |  Hypervisor [7]                                     |
+--------------------------+                           +-----------------------------------------------------+

Key:

[1]  - Kata Runtime binary is called `containerd-shim-kata-v2`:
       - https://github.com/kata-containers/kata-containers/tree/main/src/runtime (golang - legacy),
       - https://github.com/kata-containers/kata-containers/tree/main/src/runtime-rs (rust).
[2]  - Such as containerd.
[3]  - https://github.com/kata-containers/kata-containers/tree/main/src/agent (rust)
[4]  - https://github.com/kata-containers/kata-containers/tree/main/src/libs/protocols/protos
       (gRPC / ttRPC / protocol buffers).
[5]  - https://github.com/kata-containers/kata-containers/tree/main/tools/osbuilder (shell)
[6]  - https://github.com/kata-containers/kata-containers/tree/main/tools/packaging/kernel (C, ASM)
[7]  - https://github.com/kata-containers/kata-containers/tree/main/docs/hypervisors.md
[8]  - New utility command: https://github.com/kata-containers/kata-containers/tree/main/src/tools/agent-ctl (rust)
[9]  - Legacy utility command: https://github.com/kata-containers/kata-containers/tree/main/src/runtime/cmd/kata-runtime (golang)
[10] - Dev/test command: https://github.com/kata-containers/kata-containers/tree/main/src/tools/kata-ctl (rust)

Note:

There are *three* rootfs's: (R), (r), and [5]!
```

## `agent-ctl` Communication

The `agent-ctl` tool normally runs "outside" the VM on "the host" system.
It creates a VSOCK socket to connect to the agent which listens
on a well-known port inside the VM.

VSOCK is a special type of socket for making a connection "across" or
"through" a Virtual Machine boundary.

Since the socket is full duplex and the agent spawns tasks to handle
each API call made on the socket, the tool can connect to the socket
even when the runtime is also connected to it.

> **Note:** See `vsock(7)` for further details.

## Kata Agent protocol

- The [Kata Containers agent protocol](https://github.com/kata-containers/kata-containers/tree/main/src/libs/protocols/protos)
  is a set of files in protocol buffers format.

- These files define the interface that the Kata agent provides to the Kata runtime.

- The `*.proto` files are converted into auto-generated golang and rust gRPC/ttRPC code that makes communicating
  with the agent easier: all you need is a VSOCK socket connected to the agent and the auto-generated binding code.

> **Note:** The protocol refers to "Sandboxes": for Kata, this means "VM" (Virtual Machine).

## `agent-ctl` code walk-through

https://github.com/kata-containers/kata-containers/tree/main/src/tools/agent-ctl

- This tool accepts Kata agent protocol commands, then sends them to the agent.
- The interesting code is in `src/client.rs`.
- For example, to create a "sandbox" (VM), you need to run it with `-c CreateSandbox`.
- The first thing the tool does is create a VSOCK connection to the agent.
- It then creates an object of the correct type (as defined by the `*.proto` files).
- It then calls the appropriate agent API (from the `*.proto` files),
  passing it the appropriate parameter.

Create VSOCK connection to the agent (in simplified pseudo code):

```rust
let client = kata_service_agent(cfg.server_address, ...)
             {
                 let ttrpc_client = create_ttrpc_client(server_address, ...)
                                    {
                                        let fd = client_create_vsock_fd();

                                        Ok(ttrpc::Client::new(fd))
                                    }

                 // XXX: AgentServiceClient: this type is auto-generated
                 // XXX: from the *.proto files.
                 Ok(AgentServiceClient::new(ttrpc_client))
             }
  ```

Let's look at the create sandbox API:

```pb
service AgentService {
    rpc CreateSandbox(CreateSandboxRequest) returns (google.protobuf.Empty);
    // ...
}

message CreateSandboxRequest {
    //  ...

    // The only member that needs to be specified
    string sandbox_id = 5;

    // ...
}
```

The tool defines a list of agent commands (`AGENT_CMDS`). In that list we see:

```rust
AgentCmd {
    name: "CreateSandbox",        // API name
    st: ServiceType::Agent,       // API type
    fp: agent_cmd_sandbox_create, // API handler function
},
```

Here's a simplified version of the handler function:

```rust

fn agent_cmd_sandbox_create(..., args, ...) {
    // Make the request object.
    let mut req: CreateSandboxRequest = utils::make_request(args)?;

    // Send CreateSandbox(CreateSandboxRequest) to the agent
    // over the VSOCK socket connection using the ttRPC Kata agent protocol.
    let reply = client.create_sandbox(..., &req);
}
```

## `agent-ctl` demo

- Let's try running a few commands:
  - `Check`
  - `GetGuestDetails`
  - `CreateSandbox`

## `kata-runtime` / `kata-ctl` summary

- The [`kata-runtime`](https://github.com/kata-containers/kata-containers/tree/main/src/runtime/cmd/kata-runtime)
  command (golang) is a _utility command_. It is **not** the runtime
  ([any more](https://github.com/kata-containers/kata-containers/blob/main/docs/design/architecture/README.md#utility-program)).

- The [`kata-ctl`](https://github.com/kata-containers/kata-containers/tree/main/src/tools/kata-ctl)
  command (rust) is the rewrite of the `kata-runtime` command.

- `kata-ctl` is currently under development.

 - Both commands provide a variety of _out of band_ functionality.
  - Neither are required to run a Kata Containers system, but they are useful!
  - Some of the commands run stand alone:
    - `version`
    - `check`
    - `env`
  - Others commands connect to the runtime or the agent:
    - `direct-volume`
    - `exec`
    - `iptables`
  - Some commands do other magic:
    - `metrics` (talks to the `kata-monitor` process).
    - `factory` (runs a server).

## Creating a container

- User asks for a container to be created by running `ctr run ...`.
- Container manager:
  - Loads the runtime shim.
  - Creates an OCI bundle.
  - Calls the
    [`Create` method on the runtime](https://github.com/containerd/containerd/blob/main/services/tasks/local.go#L166)
    like this:

    ```go
    // XXX: opts.RootFs= and opts.Spec= for the OCI spec, etc.
    rtime.Create(ctx, r.ContainerID, opts)
    ```
  - The runtime:
    - Reads the OCI spec.
    - Reads the Kata config file.
    - Launches the configured hypervisor.
    - Sends the appropriate hypervisor config to the hypervisor.
  - The hypervisor starts a VM.
  - The VM boots.
  - The Kata agent starts in the VM.
  - The runtime connects to the agent and requests that it creates a container inside the VM.
  - The runtime sends the OCI spec to the agent.
  - The agent creates the container inside the VM.
  - The agent starts the workload inside the container.

> **Note:** This is a very simplified view of the process!

## The End

Thanks for not falling asleep! ;)

## References

- [Kata Containers architecture document (legacy golang implementation)](https://github.com/kata-containers/kata-containers/blob/main/docs/design/architecture/README.md).

- [Kata Containers architecture document (new runtime-rs (rust) implementation)](https://github.com/kata-containers/kata-containers/tree/main/docs/design/architecture_3.0).

- [The OCI runtime specification](https://github.com/opencontainers/runtime-spec) (quite readable ;-)

- [The OCI bundle specification](https://github.com/opencontainers/runtime-spec/blob/main/bundle.md).

- [Containerd shim v2 specification](https://github.com/containerd/containerd/tree/main/runtime/v2).

- Man pages:
  - `vsock(7)`.
  - `namespaces(7)`.
  - `cgroups(7)`.
