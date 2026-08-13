// Deterministic fake Pikafish helper for PikafishKit tests. Scenarios are
// selected by argv[1] so tests can exercise handshake variants, flooding,
// malformed output, missing bestmove, stop-ignoring, crashes, and illegal
// bestmoves without a real engine. Received stdin lines are appended to the
// file named by FAKE_LOG_PATH when set.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *scenario = "normal";
static FILE *log_file = NULL;

static void log_line(const char *line) {
  if (log_file != NULL) {
    fputs(line, log_file);
    fputc('\n', log_file);
    fflush(log_file);
  }
}

static int env_ms(const char *name, int fallback) {
  const char *value = getenv(name);
  if (value == NULL || *value == '\0') {
    return fallback;
  }
  return atoi(value);
}

static void emit_handshake(void) {
  printf("id name FakeEngine %s\n", scenario);
  printf("id author PikafishKit tests\n");
  if (strcmp(scenario, "option-not-advertised") != 0) {
    printf("option name Hash type spin default 16 min 1 max 33554432\n");
    printf("option name Threads type spin default 1 min 1 max 1024\n");
    printf("option name Ponder type check default false\n");
  }
  printf("option name MultiPV type spin default 1 min 1 max 128\n");
  printf("option name Move Overhead type spin default 10 min 0 max 5000\n");
  printf("option name EvalFile type string default pikafish.nnue\n");
  if (strcmp(scenario, "option-variants") == 0) {
    printf("option name Style type combo default Normal var Normal var Aggressive\n");
    printf("option name Clear Hash type button\n");
    printf("option name MalformedSpin type spin default 1\n");
    printf("option name Spaces In Name type string default hello world\n");
  }
  printf("uciok\n");
  fflush(stdout);
}

static void emit_readyok(void) {
  if (strcmp(scenario, "slow-isready") == 0) {
    usleep(600 * 1000);
  }
  printf("readyok\n");
  fflush(stdout);
}

static void emit_search_lines(void) {
  if (strcmp(scenario, "immediate-bestmove") == 0) {
    return;
  }
  if (strcmp(scenario, "many-info-lines") == 0) {
    for (int i = 1; i <= 4105; i++) {
      printf("info depth %d score cp %d nodes %d pv b2b3 b7b6\n", i, i, i);
    }
    fflush(stdout);
    return;
  }
  int count = env_ms("FAKE_INFO_LINES", 3);
  for (int i = 1; i <= count; i++) {
    if (strcmp(scenario, "malformed") == 0) {
      printf("info depth notanumber seldepth 9 score cp 99999999999999999999 "
             "nodes xyz nps 123 time -7 hashfull 42 pv b2b3 z9x9 b7b6\n");
      printf("info unknown-token junk more junk\n");
      printf("info depth %d score cp %d nodes %d pv b2b3 b7b6\n", i, 35 + i, 1000 * i);
    } else if (strcmp(scenario, "flood") == 0) {
      for (int j = 0; j < 2000; j++) {
        printf("info depth %d score cp %d nodes %d nps %d\n", 10 + j % 5, j, 1000 * j, 50000);
      }
      break;
    } else if (strcmp(scenario, "stderr-flood") == 0) {
      for (int j = 0; j < 2000; j++) {
        fprintf(stderr, "stderr noise line %d that is bounded by the reader\n", j);
      }
      fflush(stderr);
      printf("info depth %d score cp %d nodes %d pv b2b3\n", i, 30 + i, 1000 * i);
    } else {
      printf("info depth %d seldepth %d score cp %d nodes %d nps %d time %d "
             "hashfull %d pv b2b3 b7b6 b3b4\n",
             i, i + 1, 30 + i, 1000 * i, 50000, 100 * i, i * 10);
    }
    fflush(stdout);
    usleep(50 * 1000);
  }
}

static void emit_bestmove(void) {
  if (strcmp(scenario, "illegal-bestmove") == 0) {
    printf("bestmove z9x9 ponder b7b6\n");
  } else {
    printf("bestmove b2b3 ponder b7b6\n");
  }
  fflush(stdout);
}

int main(int argc, char **argv) {
  const char *scenario_env = getenv("FAKE_SCENARIO");
  if (scenario_env != NULL && *scenario_env != '\0') {
    scenario = scenario_env;
  } else if (argc > 1) {
    scenario = argv[1];
  }
  const char *log_path = getenv("FAKE_LOG_PATH");
  if (log_path != NULL && *log_path != '\0') {
    log_file = fopen(log_path, "a");
  }

  char line[8192];
  int searching = 0;
  int stop_seen = 0;

  if (strcmp(scenario, "crash-early") == 0) {
    return 42;
  }

  while (fgets(line, sizeof(line), stdin) != NULL) {
    line[strcspn(line, "\r\n")] = '\0';
    log_line(line);

    if (strncmp(line, "uci", 3) == 0 && line[3] == '\0') {
      if (strcmp(scenario, "slow-handshake") == 0) {
        usleep(600 * 1000);
      }
      emit_handshake();
    } else if (strcmp(line, "isready") == 0) {
      emit_readyok();
      if (strcmp(scenario, "crash-while-ready") == 0) {
        usleep(100 * 1000);
        return 9;
      }
    } else if (strcmp(line, "ucinewgame") == 0) {
      /* no response needed */
    } else if (strncmp(line, "setoption", 9) == 0) {
      /* no response needed */
    } else if (strncmp(line, "position", 8) == 0) {
      /* no response needed */
    } else if (strcmp(line, "go") == 0 || strncmp(line, "go ", 3) == 0) {
      searching = 1;
      stop_seen = 0;
      if (strcmp(scenario, "crash-on-go") == 0) {
        return 7;
      }
      if (strcmp(scenario, "no-bestmove") == 0) {
        emit_search_lines();
        for (;;) {
          /* keep the session waiting; never emit bestmove, never exit */
          usleep(200 * 1000);
        }
      }
      emit_search_lines();
      if (strcmp(scenario, "ignore-stop") == 0) {
        for (;;) {
          usleep(200 * 1000);
          if (stop_seen) {
            /* ignore stop: keep searching until quit */
            continue;
          }
        }
      }
      emit_bestmove();
      searching = 0;
    } else if (strcmp(line, "stop") == 0) {
      stop_seen = 1;
      if (searching && strcmp(scenario, "ignore-stop") != 0) {
        emit_bestmove();
        searching = 0;
      }
    } else if (strcmp(line, "quit") == 0) {
      if (log_file != NULL) {
        fclose(log_file);
      }
      return 0;
    }
  }

  if (log_file != NULL) {
    fclose(log_file);
  }
  return 0;
}
