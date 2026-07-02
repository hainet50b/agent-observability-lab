package lab.agentobservability.callers;

import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;
import java.util.stream.Stream;

public enum Agent {

    CLAUDE("claude", "../../stacks/claude-elastic") {
        @Override
        List<String> argv(String executable, String prompt) {
            return List.of(executable, "-p", prompt);
        }

        @Override
        Map<String, String> env(LaunchContext ctx) {
            return Map.of(
                    "TRACEPARENT", ctx.traceparent(),
                    "OTEL_RESOURCE_ATTRIBUTES", "app.name=" + ctx.appName());
        }
    };

    private final String defaultCommand;
    private final String defaultWorkingDir;

    Agent(String defaultCommand, String defaultWorkingDir) {
        this.defaultCommand = defaultCommand;
        this.defaultWorkingDir = defaultWorkingDir;
    }

    String defaultCommand() {
        return defaultCommand;
    }

    String defaultWorkingDir() {
        return defaultWorkingDir;
    }

    abstract List<String> argv(String executable, String prompt);

    abstract Map<String, String> env(LaunchContext ctx);

    static Agent from(String name) {
        String wanted = (name == null || name.isBlank()) ? CLAUDE.name() : name;
        return Stream.of(values())
                .filter(a -> a.name().equalsIgnoreCase(wanted))
                .findFirst()
                .orElseThrow(() -> new IllegalStateException(
                        "caller.agent='" + wanted + "' is not supported yet; implemented: " + supported())
                );
    }

    private static String supported() {
        return Stream.of(values()).map(a -> a.name().toLowerCase()).collect(Collectors.joining(", "));
    }
}
