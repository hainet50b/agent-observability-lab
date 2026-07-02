package lab.agentobservability.callers;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "caller")
public record CallerProperties(
        String agent,
        String name,
        String prompt,
        String command,
        String workingDir) {
}
