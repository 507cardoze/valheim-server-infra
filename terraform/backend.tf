terraform {
  # Backend settings are supplied at init time so organization and workspace
  # identifiers are not embedded in the repository.
  backend "remote" {}
}

