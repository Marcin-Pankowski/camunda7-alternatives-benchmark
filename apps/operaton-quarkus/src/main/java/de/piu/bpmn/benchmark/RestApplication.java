package de.piu.bpmn.benchmark;

import jakarta.ws.rs.ApplicationPath;
import jakarta.ws.rs.core.Application;
import java.util.HashSet;
import java.util.Set;
import org.operaton.bpm.engine.rest.impl.OperatonRestResources;

/** The engine REST API under /engine-rest, like the Spring Boot starter. */
@ApplicationPath("/engine-rest")
public class RestApplication extends Application {
  @Override
  public Set<Class<?>> getClasses() {
    Set<Class<?>> classes = new HashSet<>(OperatonRestResources.getResourceClasses());
    classes.addAll(OperatonRestResources.getConfigurationClasses());
    return classes;
  }
}
