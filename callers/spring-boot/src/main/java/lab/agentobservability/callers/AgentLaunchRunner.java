package lab.agentobservability.callers;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

import io.micrometer.tracing.Span;
import io.micrometer.tracing.Tracer;
import io.micrometer.tracing.propagation.Propagator;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.ExitCodeGenerator;
import org.springframework.stereotype.Component;

@Component
public class AgentLaunchRunner implements CommandLineRunner, ExitCodeGenerator {

    private static final Logger log = LoggerFactory.getLogger(AgentLaunchRunner.class);

    private final CallerProperties properties;
    private final Tracer tracer;
    private final Propagator propagator;
    private int exitCode = 0;

    public AgentLaunchRunner(CallerProperties properties, Tracer tracer, Propagator propagator) {
        this.properties = properties;
        this.tracer = tracer;
        this.propagator = propagator;
    }

    @Override
    public void run(String... args) throws Exception {
        Agent agent = Agent.from(properties.agent());

        String executable = (properties.command() == null || properties.command().isBlank())
                ? agent.defaultCommand() : properties.command();
        File workingDir = resolveWorkingDir(agent);

        Span span = tracer.nextSpan().name("caller").start();
        String appName = properties.appName();

        try (Tracer.SpanInScope scope = tracer.withSpan(span)) {
            ProcessBuilder builder = new ProcessBuilder(agent.argv(executable, properties.prompt()));
            builder.directory(workingDir);
            builder.environment().putAll(agent.env(new LaunchContext(traceparent(span), appName)));
            builder.redirectError(ProcessBuilder.Redirect.INHERIT);

            log.info("launching {} ('{}') in {}", agent.name().toLowerCase(), executable, workingDir);
            log.info("trace.id={}", span.context().traceId());
            log.info("app.name={}", appName);
            log.info("prompt: {}", properties.prompt());

            try {
                Process process = builder.start();
                process.getOutputStream().close();
                String response = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8).strip();
                this.exitCode = process.waitFor();

                log.info("response: {}", response);
                log.info("{} exited with code {}", executable, exitCode);
            } catch (IOException e) {
                this.exitCode = 127;
                log.error("could not start '{}' — is the CLI on PATH? (override with --caller.command=<path>): {}",
                        executable, e.getMessage());
            }
        } finally {
            span.end();
        }
    }

    private String traceparent(Span span) {
        Map<String, String> carrier = new HashMap<>();
        propagator.inject(span.context(), carrier, Map::put);
        return carrier.get("traceparent");
    }

    private File resolveWorkingDir(Agent agent) {
        String configured = properties.workingDir();
        Path base = (configured == null || configured.isBlank())
                ? Path.of(System.getProperty("user.dir"), agent.defaultWorkingDir())
                : Path.of(configured);
        return base.normalize().toFile().getAbsoluteFile();
    }

    @Override
    public int getExitCode() {
        return exitCode;
    }
}
