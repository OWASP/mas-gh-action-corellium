# mas-gh-action-corellium

## Setup Instructions

1. Set the `CORELLIUM_API_TOKEN` secret (see [Corellium documentation](https://support.corellium.com/administration/api-token) and [GitHub documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets))
2. Set the `CORELLIUM_API_ENDPOINT` environmental variable to the domain for your server (see [GitHub documentation](https://docs.github.com/actions/learn-github-actions/variables))
   - For example, `https://exampledomain.enterprise.corellium.com` or `https://corellium.examplecompany.com`
3. Set the `CORELLIUM_DEFAULT_PROJECT` actions variable to the project identifier you'd like to use to create Corellium devices (see [GitHub documentation](https://docs.github.com/actions/learn-github-actions/variables))
