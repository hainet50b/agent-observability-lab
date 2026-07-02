package lab.agentobservability.callers;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "caller")
public record CallerProperties(
        String agent,
        String appName,
        String prompt,
        String command,
        String workingDir) {
}
