package de.piu.bpmn.benchmark;

import jakarta.ws.rs.ApplicationPath;
import jakarta.ws.rs.core.Application;
import java.util.HashSet;
import java.util.Set;
import org.cibseven.bpm.engine.rest.impl.CamundaRestResources;

/** The engine REST API under /engine-rest, like the Spring Boot starter. */
@ApplicationPath("/engine-rest")
public class RestApplication extends Application {
  @Override
  public Set<Class<?>> getClasses() {
    Set<Class<?>> classes = new HashSet<>(CamundaRestResources.getResourceClasses());
    classes.addAll(CamundaRestResources.getConfigurationClasses());
    return classes;
  }
}
