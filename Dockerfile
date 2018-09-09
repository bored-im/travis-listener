FROM ruby:2.5.1

RUN mkdir /app
WORKDIR /app

COPY Gemfile* ./
RUN bundle install

COPY . .

CMD ./bin/runner
