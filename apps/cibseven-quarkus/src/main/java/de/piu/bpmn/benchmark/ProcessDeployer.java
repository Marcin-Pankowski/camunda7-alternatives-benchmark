package de.piu.bpmn.benchmark;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import org.cibseven.bpm.engine.RepositoryService;
import org.cibseven.bpm.quarkus.engine.extension.event.CamundaEngineStartupEvent;

/** The extension has no auto-deployment: deploy the models at startup, unchanged models only once (like the Spring Boot starter). */
@ApplicationScoped
public class ProcessDeployer {
  void deploy(@Observes CamundaEngineStartupEvent event, RepositoryService repositoryService) {
    repositoryService.createDeployment()
        .name("benchmark")
        .enableDuplicateFiltering(true)
        .addClasspathResource("scenario-a.bpmn")
        .addClasspathResource("scenario-b.bpmn")
        .addClasspathResource("pricing.dmn")
        .deploy();
  }
}
