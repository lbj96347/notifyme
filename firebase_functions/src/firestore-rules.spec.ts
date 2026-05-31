/**
 * Firestore security-rules tests for NotifyMe.
 *
 * These run against the Firestore emulator and exercise `firestore.rules`
 * (at the repo root). Unlike the other `*.test.ts` files — which are pure
 * unit tests run by `npm test` — these need the emulator, so they live in a
 * `*.spec.ts` file and are run by `npm run test:rules`, which wraps them in
 * `firebase emulators:exec`. Java 11+ must be the active JDK for the emulator.
 *
 * Coverage: ownership-by-`uid` for the three collections (`users`, `devices`,
 * `notifications`), plus the server-only `create` constraint on notifications.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, beforeEach, describe, test } from "node:test";

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  deleteDoc,
  doc,
  getDoc,
  setDoc,
  setLogLevel,
  updateDoc,
} from "firebase/firestore";

const PROJECT_ID = "notifyme-rules-test";
const ALICE = "alice";
const BOB = "bob";

let env: RulesTestEnvironment;

// Authenticated Firestore handle for a given uid.
const dbFor = (uid: string) => env.authenticatedContext(uid).firestore();

// Seed a document straight to Firestore, bypassing the rules under test.
async function seed(path: string, data: Record<string, unknown>) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), path), data);
  });
}

before(async () => {
  // Silence the noisy client SDK logs; emulator warnings are still useful.
  setLogLevel("error");
  env = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: readFileSync(join(__dirname, "..", "..", "firestore.rules"), "utf8"),
    },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
});

after(async () => {
  await env.cleanup();
});

describe("users/{uid}", () => {
  test("owner can read and write their own profile", async () => {
    const db = dbFor(ALICE);
    await assertSucceeds(
      setDoc(doc(db, "users", ALICE), { uid: ALICE, email: "a@example.com" }),
    );
    await assertSucceeds(getDoc(doc(db, "users", ALICE)));
  });

  test("a user cannot read or write someone else's profile", async () => {
    await seed(`users/${BOB}`, { uid: BOB, email: "b@example.com" });
    const db = dbFor(ALICE);
    await assertFails(getDoc(doc(db, "users", BOB)));
    await assertFails(setDoc(doc(db, "users", BOB), { uid: BOB, email: "x" }));
  });
});

describe("devices/{deviceId}", () => {
  test("owner can register a device carrying their own uid", async () => {
    const db = dbFor(ALICE);
    await assertSucceeds(
      setDoc(doc(db, "devices", "d1"), { uid: ALICE, fcmToken: "t", platform: "ios" }),
    );
  });

  test("a user cannot create a device claiming another uid", async () => {
    const db = dbFor(ALICE);
    await assertFails(
      setDoc(doc(db, "devices", "d2"), { uid: BOB, fcmToken: "t", platform: "ios" }),
    );
  });

  test("a user cannot read or delete another user's device", async () => {
    await seed("devices/d3", { uid: BOB, fcmToken: "t", platform: "android" });
    const db = dbFor(ALICE);
    await assertFails(getDoc(doc(db, "devices", "d3")));
    await assertFails(deleteDoc(doc(db, "devices", "d3")));
  });
});

describe("notifications/{notificationId}", () => {
  test("clients cannot create notifications, even their own", async () => {
    const db = dbFor(ALICE);
    await assertFails(
      setDoc(doc(db, "notifications", "n1"), {
        uid: ALICE,
        title: "t",
        message: "m",
        read: false,
      }),
    );
  });

  test("owner can read and mark their own notification read", async () => {
    await seed("notifications/n2", { uid: ALICE, title: "t", message: "m", read: false });
    const db = dbFor(ALICE);
    await assertSucceeds(getDoc(doc(db, "notifications", "n2")));
    await assertSucceeds(updateDoc(doc(db, "notifications", "n2"), { read: true }));
  });

  test("owner cannot reassign a notification to another uid", async () => {
    await seed("notifications/n3", { uid: ALICE, title: "t", message: "m", read: false });
    const db = dbFor(ALICE);
    await assertFails(updateDoc(doc(db, "notifications", "n3"), { uid: BOB }));
  });

  test("a user cannot read or delete another user's notification", async () => {
    await seed("notifications/n4", { uid: BOB, title: "t", message: "m", read: false });
    const db = dbFor(ALICE);
    await assertFails(getDoc(doc(db, "notifications", "n4")));
    await assertFails(deleteDoc(doc(db, "notifications", "n4")));
  });
});
