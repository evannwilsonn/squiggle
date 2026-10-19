# Squiggle as one container: a Phoenix release with the trained sketch network inside.
#   build  compiles the app (EXLA brings its compiled XLA library), builds the CSS and JS,
#          and assembles the release
#   run    Debian slim with only what the release needs, as a non-root user on port 7860
#          (the port and uid Hugging Face Spaces expects)
FROM elixir:1.18-otp-27 AS build
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets
RUN mix compile && mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM debian:bookworm-slim AS run
RUN apt-get update -y && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/* && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
RUN useradd --create-home --uid 1000 squiggle
WORKDIR /app
COPY --from=build --chown=squiggle /app/_build/prod/rel/squiggle ./
USER squiggle
ENV MIX_ENV=prod PHX_SERVER=true PORT=7860
EXPOSE 7860
CMD ["/app/bin/server"]
