FROM --platform=linux/amd64 haskell:8.10.7 as builder 
# for accessing private repositories
RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts
# copy the content of the repository to the container
COPY . . 
# grant access right to private repositories during the build process
RUN --mount=type=ssh stack install
# multi-stage build
FROM --platform=linux/amd64 haskell:8.10.7
# copy the built binary 
COPY --from=builder /root/.local/bin/keelungc /usr/local/bin/
ENTRYPOINT [ "keelungc" ]