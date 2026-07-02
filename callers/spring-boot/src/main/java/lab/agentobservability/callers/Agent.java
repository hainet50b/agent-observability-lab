package lab.agentobservability.callers;

import java.io.File;
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
        Map<String, String> traceEnv(TraceHandoff handoff) {
            return Map.of(
                    "TRACEPARENT", handoff.traceparent(),
                    "OTEL_RESOURCE_ATTRIBUTES", "caller.name=" + handoff.name()
            );
        }
    },

    CODEX("codex", "../../stacks/codex-elastic") {
        @Override
        List<String> argv(String executable, String prompt) {
            return List.of(executable, "exec", prompt);
        }

        @Override
        Map<String, String> traceEnv(TraceHandoff handoff) {
            return Map.of("OTEL_RESOURCE_ATTRIBUTES", "caller.name=" + handoff.name());
        }

        @Override
        Map<String, String> extraEnv(File workingDir) {
            return Map.of("CODEX_HOME", new File(workingDir, ".codex").getAbsolutePath());
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

    abstract Map<String, String> traceEnv(TraceHandoff handoff);

    Map<String, String> extraEnv(File workingDir) {
        return Map.of();
    }

    static Agent from(String name) {
        String wanted = (name == null || name.isBlank()) ? CLAUDE.name() : name;
        return Stream.of(values())
                .filter(a -> a.name().equalsIgnoreCase(wanted))
                .findFirst()
                .orElseThrow(() -> new IllegalStateException(
                        "caller.agent='" + wanted + "' is not supported yet; implemented: " + supported()
                ));
    }

    private static String supported() {
        return Stream.of(values()).map(a -> a.name().toLowerCase()).collect(Collectors.joining(", "));
    }
}
