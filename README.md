APB Test Shim
=============

This project exists to assist APB developers in APB testing.

# Getting started

Simply copy [.travis.example.yml](.travis.example.yml) into your project as
`.travis.yml`, [enable Travis CI on your
project](https://docs.travis-ci.com/user/getting-started/), modify the
environment variables for the OpenShift and Kubernetes versions you wish to
test against, update the `export apb_name` value, and you are all set.
