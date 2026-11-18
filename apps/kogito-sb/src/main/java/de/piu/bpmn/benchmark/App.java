package de.piu.bpmn.benchmark;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

// Kogito generates its beans (process, REST resource) into org.kie.kogito.* and this package.
@SpringBootApplication(scanBasePackages = {"org.kie.kogito.**", "de.piu.bpmn.benchmark.**"})
public class App {
  public static void main(String[] args) {
    SpringApplication.run(App.class, args);
  }
}
