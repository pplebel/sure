ARG UPSTREAM_IMAGE
FROM ${UPSTREAM_IMAGE}
USER root
RUN apt-get update -qq && apt-get install --no-install-recommends -y build-essential libyaml-dev libpq-dev pkg-config git postgresql-client-17 && rm -rf /var/lib/apt/lists/*
ENV BUNDLE_WITHOUT=""
RUN bundle install
USER rails
COPY --chown=rails:rails . /rails/
COPY --chown=rails:rails personal/tests/full_schema.rb /rails/config/initializers/personal_full_test_schema.rb
