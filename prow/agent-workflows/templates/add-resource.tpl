    add-resource:
        description: "ACK resource addition workflow"
        image: {{printf "%s:%s" $.ImageContext.ImageRepo (index $.ImageContext.Images "add-resource") }}
        command: ["./prow-job.sh"]
        required_args: ["service", "resource"]
        optional_args: ["model", "aws-sdk-version"]
        environment:
            GITHUB_ORG: ${TEST_INFRA_ORG}
            GITHUB_EMAIL_PREFIX: "82905295"
            GITHUB_ACTOR: ack-bot
        environmentFromSecrets:
            GITHUB_TOKEN:
                name: agent-github-pat-token
                key: token
        timeout: "45m"
        resources:
            cpu: "2"
            memory: "4Gi"