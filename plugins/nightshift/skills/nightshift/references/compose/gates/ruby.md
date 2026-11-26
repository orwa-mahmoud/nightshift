# Ruby — Gemfile and a Rake test task

## Detect

`Gemfile` and `Rakefile` in the same package directory.

Match: stack

## Item gate

From that directory, run `bundle check` to confirm dependencies are installed. If
`bundle exec rake -AT` lists an exact `rake test` task, use `bundle exec rake test`
as the item gate.

## Site inspection

Use the project's existing broader CI task when one is documented.

## Notes

Use the project's Ruby and Bundler versions. If Rake or the test task is missing,
use the test command documented by the project. Missing dependencies or a missing
test command are setup gaps.
