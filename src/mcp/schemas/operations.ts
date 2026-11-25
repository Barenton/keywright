// Every operation edit_animation publishes, of both kinds of clip; each says which clips it is for.
import { keyframeOperations } from "./keyframeOperations.js";
import { sharedOperations } from "./sharedOperations.js";
import { curveOperations } from "./curveOperations.js";
import { bodyOperations } from "./bodyOperations.js";

export const operations = [...keyframeOperations, ...sharedOperations, ...curveOperations, ...bodyOperations] as const;
