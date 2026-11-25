// Every operation edit_animation publishes, of both kinds of clip; each says which clips it is for.
import { bodyOperations } from "./bodyOperations.js";
import { curveOperations } from "./curveOperations.js";
import { keyframeOperations } from "./keyframeOperations.js";
import { sharedOperations } from "./sharedOperations.js";

export const operations = [...keyframeOperations, ...sharedOperations, ...curveOperations, ...bodyOperations] as const;
