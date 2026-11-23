# Linux build of the AnySnap MCP server.
# AnySnap itself only works on macOS (it captures Mac windows); this image exists so MCP
# directories such as Glama can start the server and list its tools. Tool calls on Linux
# return an error telling the user to install AnySnap on a Mac.
FROM swift:6.1-jammy AS build
WORKDIR /src
COPY Package.swift ./
COPY Sources ./Sources
RUN swift build -c release --product anysnap --static-swift-stdlib \
 && cp "$(swift build -c release --show-bin-path)/anysnap" /usr/local/bin/anysnap

FROM ubuntu:22.04
COPY --from=build /usr/local/bin/anysnap /usr/local/bin/anysnap
ENTRYPOINT ["anysnap", "mcp"]
