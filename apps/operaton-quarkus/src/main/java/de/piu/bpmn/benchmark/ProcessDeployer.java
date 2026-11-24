package de.piu.bpmn.benchmark;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import org.operaton.bpm.engine.RepositoryService;
import org.operaton.bpm.quarkus.engine.extension.event.OperatonEngineStartupEvent;

/** The extension has no auto-deployment: deploy the models at startup, unchanged models only once (like the Spring Boot starter). */
@ApplicationScoped
public class ProcessDeployer {
  void deploy(@Observes OperatonEngineStartupEvent event, RepositoryService repositoryService) {
    repositoryService.createDeployment()
        .name("benchmark")
        .enableDuplicateFiltering(true)
        .addClasspathResource("scenario-a.bpmn")
        .addClasspathResource("scenario-b.bpmn")
        .addClasspathResource("pricing.dmn")
        .deploy();
  }
}
