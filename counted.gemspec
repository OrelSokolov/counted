require_relative "lib/counted/version"

Gem::Specification.new do |spec|
  spec.name = "counted"
  spec.version = Counted::VERSION
  spec.authors = ["Oleg Orlov"]
  spec.email = ["orelcokolov@gmail.com"]

  spec.summary = "Exact row counts for large tables using database triggers"
  spec.description = "Maintains exact row counts in a metadata table via PostgreSQL triggers. " \
                      "No full table scans on COUNT(*) — instant results for billion-row tables."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"] = "https://github.com/user/counted"
  spec.metadata["source_code_uri"] = "https://github.com/user/counted"

  spec.files = Dir.glob("lib/**/*.rb") + Dir.glob("lib/tasks/*.rake") + %w[README.md CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 6.1"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "pg", "~> 1.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
